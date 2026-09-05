local arcanum = require("parley.providers.arcanum.provider")
local transport = require("parley.providers.arcanum.transport")
local async = require("plenary.async")

describe("Arcanum issue resolution", function()
  local p, saved, calls, result, cancelled
  before_each(function()
    p = arcanum.new({ _auth = {
      read_token = function()
        return "test-token"
      end,
    } })
    saved = transport.http_start
    calls, cancelled = {}, 0
    result = { ok = true, data = { id = 42 } }
    transport.http_start = function(_, method, path, body, callback, opts)
      assert.equals("test-token", p._token)
      calls[#calls + 1] = { method, path, body, opts }
      callback(result)
      return {
        cancel = function()
          cancelled = cancelled + 1
        end,
      }
    end
  end)
  after_each(function()
    transport.http_start = saved
  end)
  it("shares exact PATCH bodies across coroutine and callback methods", function()
    local done
    async.run(function()
      p:resolve({}, "42")
      p:unresolve({}, "42")
      done = true
    end)
    assert.is_true(vim.wait(200, function()
      return done
    end))
    p:begin_resolve({}, "42", function(r)
      assert.is_true(r.ok)
    end)
    p:begin_unresolve({}, "42", function(r)
      assert.is_true(r.ok)
    end)
    for i, call in ipairs(calls) do
      assert.equals("PATCH", call[1])
      assert.equals("/v1/public/review-requests-comments/42", call[2])
      assert.same({ issue_status = i % 2 == 1 and "resolved" or "open" }, call[3])
      assert.same({ retry_policy = "none" }, call[4])
    end
    assert.equals(4, #calls)
  end)
  it("preserves uncertain failures and delegates cancellation", function()
    result = { ok = false, uncertain = true, cancelled = true, err = "Check the review" }
    local received
    local h = p:begin_resolve({}, "42", function(r)
      received = r
    end)
    h.cancel()
    assert.same(result, received)
    assert.equals(1, cancelled)
  end)
  it("reports missing credentials through the callback without starting HTTP", function()
    p._token = nil
    p._auth.read_token = function()
      return nil, "No token"
    end
    local received
    local h = p:begin_resolve({}, "42", function(r)
      received = r
    end)
    assert.is_false(received.ok)
    assert.matches("No token", received.err)
    assert.same({}, calls)
    h.cancel()
  end)
  it("propagates permission failures without mapping a comment", function()
    result = { ok = false, err = "Arcanum HTTP 403" }
    local received
    p:begin_unresolve({}, "42", function(r)
      received = r
    end)
    assert.same(result, received)
  end)
end)
