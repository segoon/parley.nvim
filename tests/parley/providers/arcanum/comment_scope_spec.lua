local scope = require("parley.providers.arcanum.comment_scope")
local requests = require("parley.providers.arcanum.requests")
local transport = require("parley.providers.arcanum.transport")
local provider = require("parley.providers.arcanum.provider")

describe("Arcanum comment PR scope recovery", function()
  local saved, p, calls, review
  before_each(function()
    saved = transport.request_start
    p = provider.new({ _auth = {
      read_token = function()
        return "token"
      end,
    } })
    dofile("tests/support/arcanum_session.lua")(p)
    calls, review = {}, { write_context = { diff_id = 42 } }
    transport.request_start = function(_, request, callback)
      calls[#calls + 1] = { request = request, callback = callback, cancelled = false }
      local call = calls[#calls]
      return {
        cancel = function()
          call.cancelled = true
          callback({ ok = false, cancelled = true, uncertain = request.retry_policy ~= "read" })
        end,
      }
    end
  end)
  after_each(function()
    transport.request_start = saved
  end)

  --- @param callback function
  --- @return parley.CancelHandle
  local function start(callback)
    return scope.start(p, review, function(pr_id)
      return requests.delete_comment(pr_id, "-3")
    end, callback)
  end

  it("recovers the owning PR through CLI metadata before a PR-scoped mutation", function()
    local result
    start(function(r)
      result = r
    end)
    assert.equals("get_diff_info", calls[1].request.operation)
    assert.equals("cli", calls[1].request.kind)
    calls[1].callback({ ok = true, data = { id = 42, pull_request_id = 12 } })
    assert.equals("cli", calls[2].request.kind)
    assert.same({ "comment", "delete", "--id", "12", "--cid", "-3" }, calls[2].request.args)
    calls[2].callback({ ok = true })
    assert.is_true(result.ok)
    assert.is_nil(review.write_context.pr_id, "Do not mutate the caller's review snapshot")
  end)
  it("does not look up metadata when PR scope is already known", function()
    review.pr = { id = "12" }
    start(function() end)
    assert.equals("delete_comment", calls[1].request.operation)
    assert.equals(1, #calls)
  end)
  it("preserves acknowledgement when cancelling hydration after recovered-scope creation", function()
    local result, count = nil, 0
    local handle = scope.start(p, review, function(pr_id)
      return requests.reply(pr_id, "-3", "reply", false)
    end, function(r)
      result, count = r, count + 1
    end, require("parley.providers.arcanum.comment_write").start)
    calls[1].callback({ ok = true, data = { id = 42, pull_request_id = 12 } })
    assert.equals("reply", calls[2].request.operation)
    calls[2].callback({ ok = true, data = { id = -4 } })
    assert.equals("get_comment", calls[3].request.operation)
    assert.equals("12", calls[3].request.args[4])
    handle.cancel()
    calls[3].callback({ ok = false, err = "late failure" })
    assert.is_true(result.ok)
    assert.equals(1, count)
  end)
  it("never sends a mutation after failed or malformed scope reads", function()
    for _, response in ipairs({
      { ok = false, err = "lookup failed" },
      { ok = true, data = vim.NIL },
      { ok = true, data = {} },
      { ok = true, data = { id = 43, pull_request_id = 12 } },
      { ok = true, data = { id = 42, pull_request_id = 0 } },
    }) do
      calls = {}
      local result
      start(function(r)
        result = r
      end)
      calls[1].callback(response)
      assert.is_false(result.ok)
      assert.is_not.equals(true, result.uncertain)
      assert.equals(1, #calls)
    end
  end)
  it("cancels the lookup without sending a mutation on late completion", function()
    local result, count = nil, 0
    local handle = start(function(r)
      result, count = r, count + 1
    end)
    handle.cancel()
    calls[1].callback({ ok = true, data = { id = 42, pull_request_id = 12 } })
    assert.is_true(calls[1].cancelled)
    assert.is_true(result.cancelled)
    assert.is_false(result.uncertain)
    assert.equals(1, count)
    assert.equals(1, #calls)
  end)
  it("cancels the current mutation after synchronous metadata completion", function()
    local raw = transport.request_start
    transport.request_start = function(owner, request, callback)
      local handle = raw(owner, request, callback)
      if request.operation == "get_diff_info" then
        callback({ ok = true, data = { id = 42, pull_request_id = 12 } })
      end
      return handle
    end
    local result
    local handle = start(function(r)
      result = r
    end)
    handle.cancel()
    assert.is_false(calls[1].cancelled)
    assert.is_true(calls[2].cancelled)
    assert.is_true(result.uncertain)
  end)
  it("rejects credentials or diff changes during lookup", function()
    for _, change in ipairs({
      function()
        p._arc_login = "changed"
      end,
      function()
        review.write_context.diff_id = 43
      end,
    }) do
      calls = {}
      local result
      start(function(r)
        result = r
      end)
      change()
      calls[1].callback({ ok = true, data = { id = 42, pull_request_id = 12 } })
      assert.is_false(result.ok)
      assert.equals(1, #calls)
      dofile("tests/support/arcanum_session.lua")(p)
      review.write_context.diff_id = 42
    end
  end)
  it("does not send under a replacement prepared account after metadata completion", function()
    local result
    start(function(r)
      result = r
    end)
    p._auth.read_token = function()
      return "replacement"
    end
    p:prepare()
    calls[1].callback({ ok = true, data = { id = 42, pull_request_id = 12 } })
    assert.is_false(result.ok)
    assert.matches("session changed", result.err)
    assert.equals(1, #calls)
  end)
end)
