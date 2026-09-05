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
  end)
end)
