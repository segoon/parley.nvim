local provider = require("parley.providers.arcanum.provider")
local transport = require("parley.providers.arcanum.transport")

local a = require("plenary.async.tests")

a.describe("exact Arcanum discovery", function()
  local saved, p, calls, response
  before_each(function()
    saved = transport.request_start
    p = provider.new({
      login = "local-user",
      _auth = {
        read_token = function()
          return "token"
        end,
      },
    })
    calls = {}
    response = { ok = true, data = { id = 8, status = "open", vcs = { from_branch = "feature" } } }
    transport.request_start = function(_, request, callback)
      calls[#calls + 1] = request
      if request.operation == "get_pr_by_branch" then
        callback(response)
      elseif request.operation == "get_active_diff" then
        callback({ ok = true, data = { id = 7, commit_ids = { head = "head" } } })
      else
        callback({ ok = true, data = { reviewers = {}, min_ships_required = 0 } })
      end
      return { cancel = function() end }
    end
  end)
  after_each(function()
    transport.request_start = saved
  end)
  a.it("loads exact branch metadata with one CLI lookup", function()
    local review = p:detect_pr("/repo", "feature")
    assert.equals("8", review.pr.id)
    assert.equals("local-user", p._viewer_login)
    assert.same({
      "pr",
      "get",
      "--from-branch",
      "feature",
      "--latest",
      "--repository",
      "arcadia",
      "--fields",
      "id,summary,status,url,author,vcs",
    }, calls[1].args)
    assert.equals(3, #calls) -- Exact PR, active diff, verdicts.
  end)
  a.it("treats only a definite missing branch result as absence", function()
    response = { ok = false, status = 404, err = "not found" }
    assert.is_nil(p:detect_pr("/repo", "feature"))
    assert.equals(1, #calls)
    for _, status in ipairs({ 400, 401, 403, 429, 503 }) do
      response = { ok = false, status = status, err = "lookup failed" }
      assert.has_error(function()
        p:detect_pr("/repo", "feature")
      end)
    end
  end)
  a.it("does not attach the latest merged, discarded, or draft PR", function()
    for _, status in ipairs({ "merged", "discarded", "draft" }) do
      calls = {}
      response.data.status = status
      assert.is_nil(p:detect_pr("/repo", "feature"))
      assert.equals(1, #calls)
    end
  end)
  a.it("does not interpret an obsolete session's 404 as absence", function()
    transport.request_start = function(_, _, callback)
      p._auth.read_token = function()
        return "replacement"
      end
      p:prepare()
      callback({ ok = false, status = 404, err = "obsolete session" })
      return { cancel = function() end }
    end
    assert.has_error(function()
      p:detect_pr("/repo", "feature")
    end)
  end)
  a.it("rejects malformed results and branch mismatches rather than hiding lookup errors", function()
    for _, data in ipairs({
      vim.NIL,
      {},
      { id = 0 },
      { id = "8" },
      { id = 8, status = "open", vcs = { from_branch = "feature-extra" } },
      { id = 8, status = "unrecognized", vcs = { from_branch = "feature" } },
    }) do
      response = { ok = true, data = data }
      assert.has_error(function()
        p:detect_pr("/repo", "feature")
      end)
    end
  end)
  a.it("keeps active PR lifecycle states readable", function()
    for _, status in ipairs({
      "open",
      "conflicts",
      "errors",
      "configuration_failed",
      "merging",
      "merge_failed",
      "uploading",
      "no_changes",
    }) do
      response.data.status = status
      assert.is_not_nil(p:detect_pr("/repo", "feature"))
    end
  end)
  a.it("makes no requests without an upstream branch", function()
    assert.is_nil(p:detect_pr("/repo", ""))
    assert.same({}, calls)
  end)
end)
