local provider = require("parley.providers.arcanum.provider")
local transport = require("parley.providers.arcanum.transport")
describe("exact Arcanum discovery", function()
  local saved, p, calls, pages, details
  before_each(function()
    saved = transport.http_run
    p = provider.new({
      login = "local-user",
      _auth = {
        read_token = function()
          return "token"
        end,
      },
    })
    calls, pages, details = {}, {}, {}
    transport.http_run = function(_, method, path, body)
      calls[#calls + 1] = { method = method, path = path, body = body }
      if path == "/v2/users/me?fields=name" then
        return { name = "token-user" }
      end
      if path == "/v1/pull-requests/cursor" then
        return pages[body.offset]
      end
      if path:find("active-diff", 1, true) then
        return { id = 7, commit_ids = { head = "head" } }
      end
      local id = tonumber(path:match("/pull%-requests/(%d+)"))
      return details[id]
    end
  end)
  after_each(function()
    transport.http_run = saved
  end)
  it("continues prefix pages until the exact branch is found", function()
    pages[0] = { pull_requests = { { id = 9 } }, has_next = true }
    pages[1] = { pull_requests = { { id = 8 } }, has_next = false }
    details[9] = { id = 9, status = "open", vcs = { from_branch = "feature-extra" } }
    details[8] = { id = 8, status = "open", vcs = { from_branch = "feature" } }
    local review = p:detect_pr("/repo", "feature")
    assert.equals("8", review.pr.id)
    assert.equals("token-user", p._viewer_login)
    assert.equals(100, calls[2].body.limit)
    assert.equals(1, calls[4].body.offset)
  end)
  it("fails malformed and nonprogressing pagination rather than reporting no review", function()
    for _, page in ipairs({ {}, { pull_requests = {}, has_next = true }, { pull_requests = {}, has_next = "true" } }) do
      pages[0] = page
      assert.has_error(function()
        p:detect_pr("/repo", "feature")
      end)
    end
  end)
  it("deduplicates candidates across pages and stops when the server is exhausted", function()
    pages[0] = { pull_requests = { { id = 9 } }, has_next = true }
    pages[1] = { pull_requests = { { id = 9 }, { id = 8 } }, has_next = false }
    details[9] = { id = 9, vcs = { from_branch = "feature-a" } }
    details[8] = { id = 8, vcs = { from_branch = "feature-b" } }
    assert.is_nil(p:detect_pr("/repo", "feature"))
    assert.equals(5, #calls) -- Viewer, two pages, two unique detail reads.
  end)
  it("rejects repeated pages and sparse details", function()
    pages[0] = { pull_requests = { { id = 9 } }, has_next = true }
    pages[1] = pages[0]
    details[9] = { id = 9, vcs = { from_branch = "feature-extra" } }
    assert.has_error(function()
      p:detect_pr("/repo", "feature")
    end)
    details[9] = { id = 9 }
    assert.has_error(function()
      p:detect_pr("/repo", "feature")
    end)
  end)
  it("makes no HTTP requests without an upstream branch", function()
    assert.is_nil(p:detect_pr("/repo", ""))
    assert.same({}, calls)
  end)
end)
