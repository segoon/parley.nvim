local provider = require("parley.providers.arcanum.provider")
local transport = require("parley.providers.arcanum.transport")
describe("exact Arcanum discovery", function()
  local saved, p, calls, pages, details
  before_each(function()
    saved = transport.request_run
    p = provider.new({
      login = "local-user",
      _auth = {
        read_token = function()
          return "token"
        end,
      },
    })
    calls, pages, details = {}, {}, {}
    transport.request_run = function(_, method, path, body)
      calls[#calls + 1] = { method = method, path = path, body = body }
      if path:find("/v1/pull-requests/cursor?fields=id,vcs(from_branch)", 1, true) then
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
    transport.request_run = saved
  end)
  it("continues prefix pages until the exact branch is found", function()
    pages[0] = { pull_requests = { { id = 9, vcs = { from_branch = "feature-extra" } } }, has_next = true }
    pages[1] = { pull_requests = { { id = 8, vcs = { from_branch = "feature" } } }, has_next = false }
    details[9] = { id = 9, status = "open", vcs = { from_branch = "feature-extra" } }
    details[8] = { id = 8, status = "open", vcs = { from_branch = "feature" } }
    local review = p:detect_pr("/repo", "feature")
    assert.equals("8", review.pr.id)
    assert.equals("local-user", p._viewer_login)
    assert.equals(100, calls[1].body.limit)
    assert.equals(1, calls[2].body.offset)
    assert.equals(5, #calls) -- Two pages, exact details, active diff, verdicts.
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
    pages[0] = { pull_requests = { { id = 9, vcs = { from_branch = "feature-extra" } } }, has_next = true }
    pages[1] = {
      pull_requests = {
        { id = 9, vcs = { from_branch = "feature-a" } },
        { id = 8, vcs = { from_branch = "feature-b" } },
      },
      has_next = false,
    }
    details[9] = { id = 9, vcs = { from_branch = "feature-a" } }
    details[8] = { id = 8, vcs = { from_branch = "feature-b" } }
    assert.is_nil(p:detect_pr("/repo", "feature"))
    assert.equals(2, #calls) -- Two pages; no candidate detail reads.
  end)
  it("rejects repeated pages and sparse details", function()
    pages[0] = { pull_requests = { { id = 9, vcs = { from_branch = "feature-extra" } } }, has_next = true }
    pages[1] = pages[0]
    details[9] = { id = 9, vcs = { from_branch = "feature-extra" } }
    assert.has_error(function()
      p:detect_pr("/repo", "feature")
    end)
    pages[0] = { pull_requests = { { id = 9 } }, has_next = false }
    assert.has_error(function()
      p:detect_pr("/repo", "feature")
    end)
  end)
  it("makes no HTTP requests without an upstream branch", function()
    assert.is_nil(p:detect_pr("/repo", ""))
    assert.same({}, calls)
  end)
end)
