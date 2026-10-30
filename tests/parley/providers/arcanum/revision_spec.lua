local provider = require("parley.providers.arcanum.provider")
local transport = require("parley.providers.arcanum.transport")
local a = require("plenary.async.tests")

a.describe("Arcanum shared review revision", function()
  a.it("requests sparse active-diff fields explicitly", function()
    local original, original_start = transport.request_run, transport.request_start
    transport.request_start = function(_, request, callback)
      assert.equals("get_pr_by_branch", request.operation)
      callback({ ok = true, data = { id = 1, status = "open", vcs = { from_branch = "users/a/feature" } } })
      return { cancel = function() end }
    end
    local requested = false
    transport.request_run = function(_, request)
      if request.operation == "get_active_diff" then
        requested = request.args[6] == "id,commit_ids(base,head,merge)"
        return requested and { id = 2, commit_ids = { base = "base", head = "abc", merge = "merged" } } or {}
      end
      return { id = 1, vcs = { from_branch = "users/a/feature", to_branch = "trunk" } }
    end
    local p = provider.new({
      login = "alice",
      _auth = {
        read_token = function()
          return "test"
        end,
      },
    })
    local ok, result = pcall(p.detect_pr, p, "/arc", "users/a/feature")
    transport.request_run, transport.request_start = original, original_start
    assert.is_true(ok)
    assert.is_true(requested)
    assert.equals("abc", result.head_sha)
    assert.equals("base", result.base_sha)
    assert.equals("merged", result.review_sha)
    assert.is_string(result.snapshot_id)
  end)
  a.it("retains read access without accepting malformed active-diff metadata", function()
    local original, original_start = transport.request_run, transport.request_start
    transport.request_start = function(_, request, callback)
      assert.equals("get_pr_by_branch", request.operation)
      callback({ ok = true, data = { id = 1, status = "open", vcs = { from_branch = "users/a/feature" } } })
      return { cancel = function() end }
    end
    local active
    transport.request_run = function(_, request)
      if request.operation == "get_active_diff" then
        return active
      end
      return { id = 1, vcs = { from_branch = "users/a/feature", to_branch = "trunk" } }
    end
    local p = provider.new({
      login = "alice",
      _auth = {
        read_token = function()
          return "test"
        end,
      },
    })
    local ok, err = pcall(function()
      for _, value in ipairs({
        vim.NIL,
        {},
        { id = "ARC:wrong", commit_ids = vim.NIL },
        { id = 0, commit_ids = { head = vim.NIL } },
      }) do
        active = value
        local result = p:detect_pr("/arc", "users/a/feature")
        assert.equals("1", result.pr.id)
        assert.equals("", result.head_sha)
        assert.is_nil(result.write_context.diff_id)
        assert.is_nil(result.write_context.diff_set_xid)
      end
    end)
    transport.request_run, transport.request_start = original, original_start
    assert.is_true(ok, tostring(err))
  end)
end)
