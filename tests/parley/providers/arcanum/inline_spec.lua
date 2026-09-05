local provider = require("parley.providers.arcanum.provider")
local transport = require("parley.providers.arcanum.transport")
local async_tests = require("plenary.async.tests")

--- @return table
local function review()
  return { head_sha = "head", write_context = { pr_id = 1, diff_id = 42, changelist = {} } }
end

--- @return table
local function comment()
  return {
    id = -123,
    author = { name = "alice" },
    content = "hello",
    created_at = "today",
    updated_at = vim.NIL,
    reply_to_id = vim.NIL,
    reactions = vim.NIL,
  }
end

describe("Arcanum inline submission", function()
  local original, original_run, p, calls, pending
  before_each(function()
    original = transport.http_start
    original_run = transport.http_run
    transport.http_run = function()
      error("unexpected coroutine transport")
    end
    calls, pending = {}, {}
    p = provider.new({
      login = "alice",
      _auth = {
        read_token = function()
          return "token"
        end,
      },
    })
    dofile("tests/support/arcanum_session.lua")(p)
    transport.http_start = function(_, method, path, body, callback)
      local call = { method = method, path = path, body = body, cancelled = false }
      calls[#calls + 1] = call
      pending[#pending + 1] = callback
      return {
        cancel = function()
          call.cancelled = true
        end,
      }
    end
  end)
  after_each(function()
    transport.http_start = original
    transport.http_run = original_run
  end)

  it("resolves a cold changelist asynchronously and uses the V2 range contract", function()
    local results = {}
    p:begin_post_top_level_comment(
      review(),
      "a.lua",
      { start_line = 3, end_line = 5 },
      { text = "hello" },
      function(result)
        results[#results + 1] = result
      end
    )
    assert.equals(1, #calls)
    assert.equals("/v2/public/diff/42/changelist?fields=path,entry_id", calls[1].path)
    pending[1]({ ok = true, data = { { path = "a.lua", entry_id = "eid:1:fixture" } } })
    assert.equals(2, #calls)
    assert.matches("^/v2/public/diff/42/comment%?fields=", calls[2].path)
    assert.same({
      content = "hello",
      entry_id = "eid:1:fixture",
      line = 3,
      size = 3,
      side = "new",
      is_draft = false,
      is_issue = false,
    }, calls[2].body)
    pending[2]({ ok = true, data = comment() })
    assert.equals(1, #results)
    assert.is_true(results[1].ok)
    assert.equals("-123", results[1].comment.id)
    assert.is_true(results[1].comment.is_own)
    assert.equals("today", results[1].comment.updated_at)
    assert.same({}, results[1].comment.reactions)
    pending[2]({ ok = true, data = comment() })
    assert.equals(1, #results)
  end)

  it("cancels lookup and ignores late completion without posting", function()
    local results = {}
    local handle = p:begin_post_top_level_comment(
      review(),
      "a.lua",
      { start_line = 1 },
      { text = "hello" },
      function(result)
        results[#results + 1] = result
      end
    )
    handle.cancel()
    handle.cancel()
    pending[1]({ ok = true, data = { { path = "a.lua", entry_id = "eid:x" } } })
    assert.is_true(calls[1].cancelled)
    assert.equals(1, #calls)
    assert.equals(1, #results)
    assert.is_true(results[1].cancelled)
  end)

  local missing_entries = { {}, { { path = "other", entry_id = "eid:x" } }, { { path = "a.lua", entry_id = vim.NIL } } }
  for _, data in ipairs(missing_entries) do
    it("refuses unavailable inline entries", function()
      local result
      p:begin_post_top_level_comment(review(), "a.lua", { start_line = 1 }, { text = "hello" }, function(r)
        result = r
      end)
      pending[1]({ ok = true, data = data })
      assert.is_false(result.ok)
      assert.equals(1, #calls)
    end)
  end

  it("fails closed on invalid review metadata and ranges", function()
    for _, change in ipairs({
      function(r)
        r.head_sha = vim.NIL
      end,
      function(r)
        r.write_context.diff_id = vim.NIL
      end,
      function(r)
        r.write_context.diff_id = "ARC:wrong"
      end,
    }) do
      local r, result = review(), nil
      change(r)
      p:begin_post_top_level_comment(r, "a.lua", { start_line = 1 }, { text = "hello" }, function(v)
        result = v
      end)
      assert.is_false(result.ok)
    end
    local result
    p:begin_post_top_level_comment(review(), "a.lua", { start_line = 3, end_line = 2 }, { text = "hello" }, function(v)
      result = v
    end)
    assert.is_false(result.ok)
    assert.equals(0, #calls)
  end)

  it("preserves lookup failures instead of posting general comments", function()
    local result
    p:begin_post_top_level_comment(review(), "a.lua", { start_line = 1 }, { text = "hello" }, function(v)
      result = v
    end)
    pending[1]({ ok = false, err = "HTTP 403" })
    assert.is_false(result.ok)
    assert.matches("403", result.err)
    assert.equals(1, #calls)
  end)

  it("uses only a cache belonging to the loaded diff and rejects malformed creation responses", function()
    local r, result = review(), nil
    r.write_context.changelist = { ["a.lua"] = "eid:stale" }
    r.write_context.changelist_diff_id = 41
    p:begin_post_top_level_comment(r, "a.lua", { start_line = 1 }, { text = "hello" }, function(v)
      result = v
    end)
    assert.equals("GET", calls[1].method)
    pending[1]({ ok = true, data = { { path = "a.lua", entry_id = "eid:fresh" } } })
    assert.equals(1, calls[2].body.size)
    pending[2]({ ok = true, data = {} })
    assert.is_false(result.ok)
    assert.is_true(result.uncertain)
  end)

  it("reports POST failure without successful completion", function()
    local result
    p:begin_post_top_level_comment(review(), "a.lua", { start_line = 1 }, { text = "hello" }, function(r)
      result = r
    end)
    pending[1]({ ok = true, data = { { path = "a.lua", entry_id = "eid:x" } } })
    pending[2]({ ok = false, err = "HTTP 409" })
    assert.is_false(result.ok)
    assert.equals("HTTP 409", result.err)
  end)

  it("forwards cancellation to POST and completes once on late success", function()
    local results = {}
    local handle = p:begin_post_top_level_comment(review(), "a.lua", { start_line = 1 }, { text = "hello" }, function(r)
      results[#results + 1] = r
    end)
    pending[1]({ ok = true, data = { { path = "a.lua", entry_id = "eid:x" } } })
    handle.cancel()
    pending[2]({ ok = true, data = comment() })
    assert.is_true(calls[2].cancelled)
    assert.equals(1, #results)
    assert.is_true(results[1].cancelled)
  end)

  it("handles immediate callbacks without replacing the current stage handle", function()
    local result, post_cancelled = nil, false
    transport.http_start = function(_, method, _, _, callback)
      if method == "GET" then
        callback({ ok = true, data = { { path = "a.lua", entry_id = "eid:x" } } })
        return {
          cancel = function()
            error("outdated handle")
          end,
        }
      end
      return {
        cancel = function()
          post_cancelled = true
        end,
      }
    end
    local handle = p:begin_post_top_level_comment(review(), "a.lua", { start_line = 1 }, { text = "hello" }, function(r)
      result = r
    end)
    handle.cancel()
    assert.is_true(post_cancelled)
    assert.is_true(result.cancelled)
  end)

  it("reports transport startup exceptions through the callback", function()
    transport.http_start = function()
      error("startup failed")
    end
    local result
    p:begin_post_top_level_comment(review(), "a.lua", { start_line = 1 }, { text = "hello" }, function(r)
      result = r
    end)
    assert.is_false(result.ok)
    assert.matches("startup failed", result.err)
  end)

  it("does not reuse an entry after the loaded diff changes", function()
    local r = review()
    p:begin_post_top_level_comment(r, "a.lua", { start_line = 1 }, { text = "hello" }, function() end)
    pending[1]({ ok = true, data = { { path = "a.lua", entry_id = "eid:first" } } })
    pending[2]({ ok = true, data = comment() })
    r.write_context.diff_id = 43
    p:begin_post_top_level_comment(r, "a.lua", { start_line = 1 }, { text = "hello" }, function() end)
    assert.equals("/v2/public/diff/43/changelist?fields=path,entry_id", calls[3].path)
  end)

  async_tests.it("shares the operation with coroutine callers and uses a valid cached entry", function()
    local r = review()
    r.write_context.changelist = { ["a.lua"] = "eid:cached" }
    r.write_context.changelist_diff_id = 42
    transport.http_start = function(_, method, _, body, callback)
      assert.equals("POST", method)
      assert.equals("eid:cached", body.entry_id)
      vim.schedule(function()
        callback({ ok = true, data = comment() })
      end)
      return { cancel = function() end }
    end
    local result = p:post_top_level_comment(r, "a.lua", { start_line = 1 }, { text = "hello" })
    assert.equals("-123", result.id)
  end)
end)
