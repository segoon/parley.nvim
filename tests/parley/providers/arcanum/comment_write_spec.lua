local write = require("parley.providers.arcanum.comment_write")
local transport = require("parley.providers.arcanum.transport")
describe("Arcanum acknowledged comment writes", function()
  local saved, calls, p
  before_each(function()
    saved, calls = transport.request_start, {}
    p = { _viewer_login = "alice" }
    transport.request_start = function(_, method, path, body, callback, opts)
      calls[#calls + 1] = { method = method, path = path, body = body, callback = callback, opts = opts }
      return { cancel = function() end }
    end
  end)
  after_each(function()
    transport.request_start = saved
  end)
  it("hydrates ID-only acknowledgements and preserves signed IDs", function()
    local result
    write.start(p, "POST", "/create", { content = "hello" }, function(r)
      result = r
    end, { pr_id = 12, retry_policy = "create" })
    calls[1].callback({ ok = true, data = { id = -456 } })
    assert.equals("GET", calls[2].method)
    assert.matches("^/v2/public/pull%-request/12/comment/%-456%?fields=", calls[2].path)
    calls[2].callback({
      ok = true,
      data = { id = -456, content = "hello", author = { name = "alice" }, created_at = "now" },
    })
    assert.is_true(result.ok)
    assert.equals("-456", result.comment.id)
    assert.is_true(result.comment.is_own)
    assert.equals(2, #calls)
  end)
  it("keeps successful creation acknowledged if hydration fails or is cancelled", function()
    for _, cancel in ipairs({ false, true }) do
      calls = {}
      local result, count = nil, 0
      local handle = write.start(p, "POST", "/create", {}, function(r)
        result, count = r, count + 1
      end, { pr_id = 12 })
      calls[1].callback({ ok = true, data = { id = 123 } })
      if cancel then
        handle.cancel()
      else
        calls[2].callback({ ok = false, err = "network" })
      end
      calls[2].callback({ ok = false, err = "late" })
      assert.is_true(result.ok)
      assert.is_nil(result.comment)
      assert.equals(1, count)
      assert.equals(2, #calls)
    end
  end)
end)
