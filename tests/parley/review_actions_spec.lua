local actions = require("parley.review_actions")
local picker = require("parley.reaction_picker_window")
local contexts = require("parley.services.write_context")
local write = require("parley.services.write")
local window = require("parley.discussion_window")

describe("confirmed review picker", function()
  local saved, ctx, selected, message, submitted, notices
  before_each(function()
    saved = {
      contexts.get,
      contexts.reason,
      picker.open,
      actions._confirm,
      write.review_action,
      write._notify,
      window.resolve_source_bufnr,
    }
    submitted, notices = 0, {}
    selected, message = nil, nil
    ctx = {
      review = { pr = { id = "12" }, head_sha = "loaded" },
      provider = {
        review_actions = function()
          return {
            { action = "sticky", label = "Sticky ship", confirmation = "Includes future diffs. Current verdict: none" },
          }
        end,
        begin_review_action = function() end,
      },
    }
    contexts.get = function()
      return ctx
    end
    contexts.reason = function(_, _, expected)
      if expected and ctx.review.head_sha ~= expected.review.head_sha then
        return "Review changed"
      end
    end
    window.resolve_source_bufnr = function()
      return 1
    end
    picker.open = function(_, _, cb)
      selected = cb
      return true
    end
    actions._confirm = function(text)
      message = text
      return true
    end
    write.review_action = function(_, action, expected)
      submitted = submitted + 1
      assert.equals("sticky", action)
      assert.equals("loaded", expected.review.head_sha)
    end
    write._notify = function(text)
      notices[#notices + 1] = text
    end
  end)
  after_each(function()
    contexts.get, contexts.reason, picker.open, actions._confirm = saved[1], saved[2], saved[3], saved[4]
    write.review_action, write._notify, window.resolve_source_bufnr = saved[5], saved[6], saved[7]
  end)
  local choice =
    { action = "sticky", label = "Sticky ship", confirmation = "Includes future diffs. Current verdict: none" }
  it("confirms the loaded PR, revision, verdict and sticky semantics", function()
    assert.is_true(actions.run(1))
    selected(choice)
    assert.matches("PR #12", message)
    assert.matches("Loaded revision: loaded", message)
    assert.matches("future diffs", message)
    assert.matches("Current verdict: none", message)
    assert.equals(1, submitted)
  end)
  it("does nothing after picker or confirmation cancellation", function()
    actions.run(1)
    selected(nil)
    assert.is_nil(message)
    actions._confirm = function()
      return false
    end
    selected(choice)
    assert.equals(0, submitted)
  end)
  it("rejects changed reviews before confirmation", function()
    actions.run(1)
    ctx.review.head_sha = "new"
    selected(choice)
    assert.equals(0, submitted)
    assert.is_nil(message)
    assert.equals("Review changed", notices[1])
  end)
  it("explains unavailable withdrawals without confirming", function()
    actions.run(1)
    local unavailable = vim.tbl_extend("force", choice, { reason = "No approval to withdraw" })
    selected(unavailable)
    assert.equals(0, submitted)
    assert.is_nil(message)
  end)
end)
