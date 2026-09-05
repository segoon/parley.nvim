local provider = require("parley.providers.arcanum.provider")
local transport = require("parley.providers.arcanum.transport")
local a = require("plenary.async.tests")

a.describe("Arcanum shared review revision", function()
  a.it("requests sparse active-diff fields explicitly", function()
    local original = transport.http_run
    local requested = false
    transport.http_run = function(_, _, path)
      if path:find("cursor", 1, true) then
        return { pull_requests = { { id = 1 } } }
      end
      if path:find("active-diff", 1, true) then
        requested = path == "/v1/pull-requests/1/active-diff?fields=id,commit_ids(head)"
        return requested and { id = 2, commit_ids = { head = "abc" } } or {}
      end
      return { id = 1, vcs = { from_branch = "users/a/feature", to_branch = "trunk" } }
    end
    local p = provider.new({ _auth = {
      read_token = function()
        return "test"
      end,
    } })
    local ok, result = pcall(p.detect_pr, p, "/arc", "users/a/feature")
    transport.http_run = original
    assert.is_true(ok)
    assert.is_true(requested)
    assert.equals("abc", result.head_sha)
    assert.equals("2", result.write_context.diff_set_xid)
  end)
  a.it("retains read access without accepting malformed active-diff metadata", function()
    local original = transport.http_run
    local active
    transport.http_run = function(_, _, path)
      if path:find("cursor", 1, true) then
        return { pull_requests = { { id = 1 } } }
      end
      if path:find("active-diff", 1, true) then
        return active
      end
      return { id = 1, vcs = { from_branch = "users/a/feature", to_branch = "trunk" } }
    end
    local p = provider.new({ _auth = {
      read_token = function()
        return "test"
      end,
    } })
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
    transport.http_run = original
    assert.is_true(ok, tostring(err))
  end)
end)
