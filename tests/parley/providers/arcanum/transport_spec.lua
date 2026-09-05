local transport = require("parley.providers.arcanum.transport")
local http = require("parley.http")
local provider = require("parley.providers.arcanum.provider")
local clock_factory = dofile("tests/support/clock.lua")

describe("Arcanum reliable transport", function()
  local saved, clock, calls, results, p, scheduler
  before_each(function()
    scheduler = require("parley.providers.arcanum.scheduler")
    saved = {
      start = http.start,
      now = scheduler._now,
      defer = scheduler._defer,
      key = transport._key,
      wall = transport._wall_time,
    }
    clock, calls, results = clock_factory.new(), {}, {}
    scheduler.reset()
    scheduler._now, scheduler._defer = clock.now, clock.defer
    transport._key = function()
      return "unique-submit-key"
    end
    transport._wall_time = function()
      return 0
    end
    p = provider.new({
      _auth = {
        read_token = function()
          return "token"
        end,
      },
      config = {
        timeout_ms = 5000,
      },
    })
    dofile("tests/support/arcanum_session.lua")(p)
    http.start = function(opts, callback)
      local call = { opts = opts, callback = callback, at = clock.time, cancelled = false }
      calls[#calls + 1] = call
      return {
        cancel = function()
          call.cancelled = true
          callback({ ok = false, cancelled = true, sent = true })
        end,
      }
    end
  end)
  after_each(function()
    scheduler.reset()
    http.start, scheduler._now, scheduler._defer = saved.start, saved.now, saved.defer
    transport._key, transport._wall_time = saved.key, saved.wall
  end)

  --- @param method? string
  --- @param policy? string
  --- @return table
  local function start(method, policy)
    return transport.http_start(p, method or "GET", "/endpoint", { content = "hello" }, function(r)
      results[#results + 1] = r
    end, { retry_policy = policy })
  end
  --- @param index integer
  --- @param status integer
  --- @param headers? table
  --- @param body? string
  local function respond(index, status, headers, body)
    calls[index].callback({
      ok = true,
      response = {
        status = status,
        headers = headers or {},
        body = body or '{"data":{"id":1}}',
        ok = status >= 200 and status < 300,
      },
    })
  end

  it("does not retry resolution PATCH even with idempotent create retries enabled", function()
    p._config.idempotent_write_retries = true
    p:begin_resolve({}, "42", function(r)
      results[#results + 1] = r
    end)
    assert.equals("PATCH", calls[1].opts.method)
    respond(1, 503)
    clock.advance(5000)
    assert.equals(1, #calls)
    assert.equals(1, #results)
    assert.is_false(results[1].ok)
    assert.is_true(results[1].uncertain)
  end)
  it("cancels resolution HTTP and ignores a late successful response", function()
    local h = p:begin_unresolve({}, "42", function(r)
      results[#results + 1] = r
    end)
    h.cancel()
    respond(1, 200)
    assert.is_true(calls[1].cancelled)
    assert.equals(1, #results)
    assert.is_true(results[1].cancelled)
    assert.is_true(results[1].uncertain)
  end)
  it("does not send queued requests after the credential changes", function()
    start()
    start()
    p._auth.read_token = function()
      return "rotated"
    end
    clock.advance(1000)
    assert.equals(1, #calls)
    assert.is_false(results[1].ok)
    assert.is_false(results[1].sent)
  end)
  it("rejects an old response even after the same provider is prepared for new credentials", function()
    start()
    p._auth.read_token = function()
      return "rotated"
    end
    dofile("tests/support/arcanum_session.lua")(p, "new-user")
    respond(1, 200)
    assert.is_false(results[1].ok)
    assert.is_nil(results[1].data)
  end)
  it("paces reads and retries across provider instances", function()
    start()
    p = provider.new({ _auth = {
      read_token = function()
        return "token"
      end,
    } })
    start()
    assert.equals(1, #calls)
    respond(1, 503)
    clock.advance(1000)
    assert.equals(2, #calls)
    clock.advance(1000)
    assert.equals(3, #calls)
    assert.equals(2000, calls[3].at)
    respond(2, 200)
    respond(3, 200)
    assert.equals(2, #results)
  end)

  it("isolates credentials and hosts and uses the slower shared interval", function()
    p._verified_token = nil -- Exercise transport queue scoping independently of account verification.
    start()
    p._config.request_interval_ms = 2000
    start()
    p._token = "other"
    start()
    p._host = "other.test"
    start()
    assert.equals(3, #calls)
    clock.advance(1999)
    assert.equals(3, #calls)
    clock.advance(1)
    assert.equals(4, #calls)
  end)

  it("removes cancelled queued work and never sends it", function()
    start()
    local handle = start()
    handle.cancel()
    assert.is_true(results[1].cancelled)
    assert.is_false(results[1].sent)
    clock.advance(1000)
    assert.equals(1, #calls)
  end)

  it("bounds queueing and HTTP execution with one deadline", function()
    p._config.timeout_ms = 500
    start()
    start()
    clock.advance(500)
    assert.equals(2, #results)
    assert.is_true(calls[1].cancelled)
    assert.equals(500, calls[1].opts.timeout_ms)
    respond(1, 200)
    assert.equals(2, #results)
  end)

  it("honors Retry-After as a shared cooldown without capping it at backoff maximum", function()
    start()
    start()
    respond(1, 429, { "retry-after: 3" })
    clock.advance(2999)
    assert.equals(1, #calls)
    clock.advance(1)
    assert.equals(2, #calls)
    clock.advance(1000)
    assert.equals(3, #calls)
    assert.equals(1000, calls[3].opts.timeout_ms)
  end)

  it("handles HTTP-date Retry-After and expires rather than sending after the deadline", function()
    start()
    respond(1, 429, { ["Retry-After"] = "Thu, 01 Jan 1970 00:00:10 GMT" })
    clock.advance(5000)
    assert.equals(1, #calls)
    assert.is_true(results[1].timed_out)
  end)

  it("sends a key but does not retry creation by default", function()
    start("POST", "create")
    assert.equals("unique-submit-key", calls[1].opts.headers["Idempotency-Key"])
    calls[1].callback({ ok = false, exit = 28, err = "lost response", sent = true })
    clock.advance(1000)
    assert.equals(1, #calls)
    assert.is_false(results[1].ok)
    assert.is_true(results[1].uncertain)
    assert.matches("Check the review", results[1].err)
  end)

  it("reuses the same key and serialized body for opt-in retries and accepts replay", function()
    p._config.idempotent_write_retries = true
    start("POST", "create")
    calls[1].callback({ ok = false, exit = 56, err = "lost response", sent = true })
    clock.advance(1000)
    assert.equals(2, #calls)
    assert.same(calls[1].opts.headers, calls[2].opts.headers)
    assert.equals(calls[1].opts.body, calls[2].opts.body)
    respond(2, 200)
    assert.is_true(results[1].ok)
  end)

  it("does not retry conflicts, authentication failures, or unknown mutations", function()
    p._config.idempotent_write_retries = true
    start("POST", "create")
    respond(1, 409)
    clock.advance(1000)
    start()
    respond(2, 403)
    clock.advance(1000)
    start("PATCH")
    respond(3, 503)
    clock.advance(1000)
    assert.equals(3, #calls)
    assert.equals(3, #results)
  end)

  it("retries cursor POSTs only when explicitly classified as reads", function()
    start("POST", "read")
    respond(1, 500)
    clock.advance(1000)
    assert.equals(2, #calls)
    assert.is_nil(calls[1].opts.headers["Idempotency-Key"])
  end)

  it("handles null envelopes, malformed JSON, and API errors without retrying", function()
    for _, body in ipairs({ "null", "{", '{"data":null,"errors":[{"message":"denied"}]}' }) do
      start()
      respond(#calls, 200, nil, body)
      clock.advance(1000)
    end
    assert.equals(3, #calls)
    assert.equals(3, #results)
    for _, r in ipairs(results) do
      assert.is_false(r.ok)
    end
  end)

  it("wakes coroutine callers through the same paced transport", function()
    local outcome
    require("plenary.async").run(function()
      outcome = transport.http_run(p, "GET", "/read")
    end)
    assert.is_nil(outcome)
    respond(1, 200)
    assert.same({ id = 1 }, outcome)
  end)

  it("exhausts retry_count and ignores callbacks from an older attempt", function()
    start()
    respond(1, 503)
    clock.advance(1000)
    respond(1, 200)
    assert.equals(0, #results)
    respond(2, 503)
    clock.advance(1000)
    respond(3, 503)
    clock.advance(1000)
    assert.equals(3, #calls)
    assert.equals(1, #results)
    assert.is_false(results[1].ok)
  end)

  it("falls back to backoff on invalid Retry-After and never retries permanent curl failures", function()
    start()
    respond(1, 429, { "Retry-After: nonsense" })
    clock.advance(1000)
    assert.equals(2, #calls)
    calls[2].callback({ ok = false, exit = 60, err = "certificate error", sent = false })
    clock.advance(1000)
    assert.equals(2, #calls)
    assert.equals(1, #results)
  end)

  it("creates a new idempotency key for each manual submission", function()
    local keys = 0
    transport._key = function()
      keys = keys + 1
      return "submit-" .. keys
    end
    start("POST", "create")
    respond(1, 201)
    clock.advance(1000)
    start("POST", "create")
    assert.equals("submit-1", calls[1].opts.headers["Idempotency-Key"])
    assert.equals("submit-2", calls[2].opts.headers["Idempotency-Key"])
  end)

  it("cancels a job returned after the deadline fires during startup", function()
    local killed = false
    http.start = function()
      clock.advance(5000)
      return {
        cancel = function()
          killed = true
        end,
      }
    end
    start("POST", "create")
    assert.is_true(killed)
    assert.is_true(results[1].timed_out)
    assert.is_true(results[1].uncertain)
  end)

  it("preserves uncertain cancellation through the inline provider", function()
    local r = {
      head_sha = "head",
      write_context = { diff_id = 42, changelist_diff_id = 42, changelist = { ["a.lua"] = "eid:entry" } },
    }
    local result
    local handle = p:begin_post_top_level_comment(r, "a.lua", { start_line = 1 }, { text = "hello" }, function(v)
      result = v
    end)
    assert.equals("unique-submit-key", calls[1].opts.headers["Idempotency-Key"])
    handle.cancel()
    assert.is_true(result.cancelled)
    assert.is_true(result.uncertain)
    assert.matches("Check the review", result.err)
  end)

  it("classifies replies as keyed writes and passes configured hosts to HTTP", function()
    p = require("parley.providers.arcanum.descriptor").factory(
      { _auth = {
        read_token = function()
          return "token"
        end,
      } },
      { host = "custom.example.test" }
    )
    dofile("tests/support/arcanum_session.lua")(p)
    p:begin_reply({}, {}, { id = "-123" }, { text = "reply" }, function(r)
      results[#results + 1] = r
    end)
    assert.matches("^https://custom.example.test/api/", calls[1].opts.url)
    assert.equals("unique-submit-key", calls[1].opts.headers["Idempotency-Key"])
    calls[1].callback({ ok = false, exit = 7, err = "failed", sent = true })
    clock.advance(1000)
    assert.equals(1, #calls)
  end)

  it("completes replies with an uncertain failure when a successful response cannot be mapped", function()
    local result
    p:begin_reply({}, {}, { id = "-123" }, { text = "reply" }, function(r)
      result = r
    end)
    respond(1, 201, nil, '{"data":{"id":1,"user":{"name":"a"},"content":null}}')
    assert.is_false(result.ok)
    assert.is_true(result.uncertain)
    assert.matches("Check the review", result.err)
  end)

  it("accepts 204 and empty successful bodies", function()
    start()
    respond(1, 204, nil, "")
    clock.advance(1000)
    start()
    respond(2, 200, nil, "")
    assert.is_true(results[1].ok)
    assert.is_true(results[2].ok)
    assert.is_nil(results[1].data)
  end)

  it("cancels retries and active requests once despite late callbacks", function()
    local handle = start()
    respond(1, 503)
    handle.cancel()
    handle.cancel()
    clock.advance(1000)
    assert.equals(1, #calls)
    assert.equals(1, #results)
    local second = start()
    second.cancel()
    assert.is_true(calls[2].cancelled)
    respond(2, 200)
    assert.equals(2, #results)
  end)
end)
