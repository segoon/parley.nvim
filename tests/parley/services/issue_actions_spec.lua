local create = require("parley.services.issue_actions")
local contexts = require("parley.services.write_context")
local reviews = require("parley.repositories.review")

describe("issue transitions", function()
  local saved, api, ctx, snapshot, calls, notices, starter
  before_each(function()
    saved = { contexts.get, reviews.get }
    calls, notices = {}, {}
    ctx = {
      provider = {
        capabilities = function()
          return {
            resolve = { available = true },
            unresolve = { available = true },
          }
        end,
        begin_resolve = function(_, _, id, cb)
          calls[#calls + 1] = id
          cb({ ok = true })
          return { cancel = function() end }
        end,
      },
      review = { pr = { id = "1" }, head_sha = "head" },
    }
    snapshot = {
      all_discussions = {
        {
          id = "root",
          issue_state = "open",
          comments = {
            { id = "reply", parent_comment_id = "root" },
            { id = "root" },
          },
        },
      },
    }
    contexts.get = function()
      return ctx
    end
    reviews.get = function()
      return snapshot
    end
    api = {
      _notify = function(msg)
        notices[#notices + 1] = msg
      end,
    }
    create(api, {
      run_action = function(_, _, start, _, opts)
        starter = start
        assert.is_true(opts.preserve_selection)
        start(function() end)
        return true
      end,
    })
  end)
  after_each(function()
    contexts.get, reviews.get = saved[1], saved[2]
  end)
  it("targets the root despite reply-first ordering and no file anchor", function()
    assert.is_true(api.set_issue_state(1, "root", "resolve"))
    assert.same({ "root" }, calls)
    assert.equals("open", snapshot.all_discussions[1].issue_state)
  end)
  it("rejects unsupported, terminal and ambiguous thread states", function()
    for _, state in ipairs({ "resolved", "dropped", "not_issue", "unknown" }) do
      snapshot.all_discussions[1].issue_state = state
      assert.is_false(api.set_issue_state(1, "root", "resolve"))
    end
    snapshot.all_discussions[1].issue_state = "open"
    for _, ancestry in ipairs({ "missing_parent", "cycle" }) do
      snapshot.all_discussions[1].ancestry = ancestry
      assert.is_false(api.set_issue_state(1, "root", "resolve"))
    end
    assert.same({}, calls)
  end)
  it("requires a real parentless root even without an ancestry diagnostic", function()
    snapshot.all_discussions[1].comments[2].parent_comment_id = "missing"
    assert.is_false(api.set_issue_state(1, "root", "resolve"))
    assert.same({}, calls)
  end)
  it("rechecks provider and issue state immediately before starting", function()
    api.set_issue_state(1, "root", "resolve")
    calls = {}
    snapshot.all_discussions[1].issue_state = "resolved"
    local result
    starter(function(r)
      result = r
    end)
    assert.is_false(result.ok)
    assert.same({}, calls)
  end)
  it("blocks custom providers without resolution capabilities", function()
    ctx.provider.capabilities = nil
    assert.is_false(api.set_issue_state(1, "root", "resolve"))
    assert.same({}, calls)
  end)
end)
