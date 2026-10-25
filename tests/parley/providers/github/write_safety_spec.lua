local github = require("parley.providers.github.provider")
local transport = require("parley.providers.github.transport")

describe("GitHub mutation safety", function()
  local available
  before_each(function()
    available, transport._gh_available = transport._gh_available, true
  end)
  after_each(function()
    transport._gh_available = available
  end)

  for _, mode in ipairs({ "coroutine", "callback" }) do
    for _, command in ipairs({
      { "gh", "api", "--method", "POST", "/comments" },
      { "gh", "api", "/reviews", "-f", "body=review" },
      { "gh", "api", "graphql", "-f", "query=mutation { x }" },
    }) do
      it("never replays a " .. mode .. " mutation: " .. table.concat(command, " "), function()
        local calls, deferred, result = 0, {}, nil
        local function response()
          calls = calls + 1
          return { code = 1, stdout = "", stderr = "connection reset by peer" }
        end
        local provider = github.new({
          repository = "owner/repo",
          _runner = response,
          _spawn = function(_, cb)
            cb(response())
            return { kill = function() end }
          end,
          _sleep = function() end,
          _defer = function(cb)
            deferred[#deferred + 1] = cb
          end,
        })
        if mode == "coroutine" then
          local ok, err = pcall(transport.gh_run, provider, command)
          assert.is_false(ok)
          assert.matches("Check the review before retrying", err, 1, true)
        else
          transport.gh_start(provider, command, function(value)
            result = value
          end)
          assert.is_not_nil(result)
          assert.is_true(result.uncertain)
          assert.matches("Check the review before retrying", result.err, 1, true)
        end
        assert.equals(1, calls)
        assert.equals(0, #deferred)
      end)
    end
  end

  it("continues retrying transient REST reads", function()
    local count = 0
    local provider = github.new({
      repository = "owner/repo",
      _runner = function()
        count = count + 1
        return count == 1 and { code = 124, stderr = "timeout" } or { code = 0, stdout = "[]" }
      end,
      _sleep = function() end,
    })
    assert.same({}, transport.gh_run(provider, { "gh", "api", "/comments" }))
    assert.equals(2, count)
  end)

  it("marks cancellation after sending as uncertain and completes once", function()
    local receive, result, completions, killed = nil, nil, 0, false
    local provider = github.new({
      repository = "owner/repo",
      _spawn = function(_, cb)
        receive = cb
        return {
          kill = function()
            killed = true
          end,
        }
      end,
    })
    local handle = transport.gh_start(provider, { "gh", "api", "--method", "POST", "/comments" }, function(value)
      completions, result = completions + 1, value
    end)
    handle.cancel()
    assert.is_true(killed)
    assert.is_not_nil(result)
    assert.is_true(result.cancelled)
    assert.is_true(result.uncertain)
    receive({ code = 0, stdout = '{"id":1}' })
    handle.cancel()
    assert.equals(1, completions)
  end)

  it("marks a malformed successful mutation response as uncertain", function()
    local result
    local provider = github.new({
      repository = "owner/repo",
      _spawn = function(_, cb)
        cb({ code = 0, stdout = "broken JSON" })
        return { kill = function() end }
      end,
    })
    transport.gh_start(provider, { "gh", "api", "--method", "POST", "/comments" }, function(value)
      result = value
    end)
    assert.is_true(result.uncertain)
  end)
  it("retries explicitly identified GraphQL reads", function()
    local calls = 0
    local provider = github.new({
      repository = "owner/repo",
      _runner = function()
        calls = calls + 1
        return calls == 1 and { code = 124, stderr = "timeout" }
          or { code = 0, stdout = '{"data":{"viewer":{"login":"alice"}}}' }
      end,
      _sleep = function() end,
    })
    local data = transport.gh_graphql(provider, "query { viewer { login } }", {}, "read")
    assert.equals("alice", data.viewer.login)
    assert.equals(2, calls)
  end)

  it("retries callback reads through the scheduled backoff", function()
    local calls, retry, result = 0, nil, nil
    local provider = github.new({
      repository = "owner/repo",
      _spawn = function(_, cb)
        calls = calls + 1
        cb(calls == 1 and { code = 124, stderr = "timeout" } or { code = 0, stdout = "[]" })
        return { kill = function() end }
      end,
      _defer = function(cb)
        retry = cb
      end,
    })
    transport.gh_start(provider, { "gh", "api", "/comments" }, function(value)
      result = value
    end)
    assert.is_nil(result)
    assert.is_function(retry)
    retry()
    assert.is_true(result.ok)
    assert.equals(2, calls)
  end)

  it("does not mark an explicit HTTP rejection as uncertain", function()
    local result
    local provider = github.new({
      repository = "owner/repo",
      _spawn = function(_, cb)
        cb({ code = 1, stderr = "gh: Validation failed (HTTP 422)" })
        return { kill = function() end }
      end,
    })
    transport.gh_start(provider, { "gh", "api", "--method", "POST", "/comments" }, function(value)
      result = value
    end)
    assert.is_false(result.ok)
    assert.is_false(result.uncertain)
  end)
end)
