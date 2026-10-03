local a = require("plenary.async.tests")
local descriptor = require("parley.providers.arcanum.descriptor")
local http = require("parley.http")
local cli = require("parley.providers.arcanum.cli")
local scheduler = require("parley.providers.arcanum.scheduler")
a.describe("configured Arcanum workflow", function()
  local saved, calls, saved_system
  before_each(function()
    saved, saved_system, calls = http.start, cli._system, {}
    scheduler.reset()
    http.start = function(opts, callback)
      calls[#calls + 1] = { backend = "http", opts = opts }
      assert.matches("^https://configured.example:8443/api/", opts.url)
      assert.equals("OAuth test-token", opts.headers.Authorization)
      local path = opts.url:match("/api(.*)")
      assert.is_true(path:find("/review?", 1, true) ~= nil or path == "/v1/public/review-requests/1/comments")
      local data = path:find("/review?", 1, true) and { reviewers = {}, min_ships_required = 0 } or {}
      callback({
        ok = true,
        sent = true,
        response = { ok = true, status = 200, headers = {}, body = vim.json.encode({ data = data }) },
      })
      return { cancel = function() end }
    end
    cli._system = function(argv, opts, callback)
      calls[#calls + 1] = { backend = "cli", argv = argv }
      assert.same(
        { "ya", "tool", "arcanum", "--json", "--api-url", "https://configured.example:8443/api" },
        vim.list_slice(argv, 1, 6)
      )
      assert.equals("test-token", opts.env.ARC_TOKEN)
      assert.is_true(opts.timeout > 0 and opts.timeout <= 500)
      local data
      if argv[8] == "list" then
        data = { pull_requests = { { id = 1, vcs = { from_branch = "feature" } } }, has_next = false }
      elseif argv[8] == "active-diff" then
        data = { id = 2, commit_ids = { head = "head", base = "base", merge = "merge" } }
      elseif argv[8] == "get" then
        data = { id = 1, vcs = { from_branch = "feature" } }
      else
        data = { id = 3, content = "reply", author = { name = "local-user" }, created_at = "now" }
      end
      callback({ code = 0, stdout = vim.json.encode(data), stderr = "" })
      return { kill = function() end }
    end
  end)
  after_each(function()
    http.start, cli._system = saved, saved_system
    scheduler.reset()
  end)
  a.it("pins one host and credential across CLI operations and retained HTTP", function()
    local auth = {
      read_token = function()
        return "test-token"
      end,
    }
    local settings = { host = "configured.example:8443", timeout_ms = 500, request_interval_ms = 1 }
    local p = descriptor.factory({ login = "local-user", _auth = auth }, settings)
    local review = p:detect_pr("/checkout", "feature")
    assert.same({}, p:fetch_discussions(review))
    assert.is_true(p:reply(review, {}, { id = "1" }, { text = "reply" }).is_own)
    p:resolve(review, "1")
    assert.equals(7, #calls)
    assert.equals("cli", calls[1].backend)
    assert.equals("http", calls[4].backend)
    assert.equals("http", calls[5].backend)
    assert.equals("cli", calls[6].backend)
    assert.equals("cli", calls[7].backend)
    assert.equals("approved", review.pr.review_status)
    assert.equals("merge", review.review_sha)
    assert.equals("configured.example:8443", p:cache_identity().host)
  end)
end)
