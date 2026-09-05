local write = require("parley.services.write")
local contexts = require("parley.repositories.context")
local providers = require("parley.repositories.provider")
local reviews = require("parley.repositories.review")
local reactions = require("parley.reactions")
local composer = require("parley.ui_states.composer")

describe("write capability boundaries", function()
  local buf, saved, p, enabled, composed, confirms, notices, sent, discussion, comment
  before_each(function()
    saved = { package.loaded["parley.discussion_window"], write._notify, write._confirm_delete }
    buf = vim.api.nvim_create_buf(false, true)
    composed, confirms, notices, sent = nil, 0, {}, 0
    enabled = false
    p = {
      capabilities = function()
        local result = {}
        for _, name in ipairs(require("parley.capabilities").actions) do
          result[name] = { available = enabled, reason = "Unavailable in this provider" }
        end
        return result
      end,
      begin_reply = function()
        sent = sent + 1
      end,
      edit = function()
        sent = sent + 1
      end,
    }
    contexts._entries[buf] = { rel_path = "f", vcs_info = { root = "/repo", vcs = "arc" } }
    providers._entries[buf] = { provider = p }
    reviews._seed(buf, { review = { pr = { id = "1" }, head_sha = "head" } }, "capability-test")
    comment = { id = "c", body = { text = "hello" }, is_own = true }
    discussion = { id = "d", comments = { comment } }
    write._notify = function(msg)
      notices[#notices + 1] = msg
    end
    write._confirm_delete = function()
      confirms = confirms + 1
      return true
    end
    package.loaded["parley.discussion_window"] = {
      show_reply_input = function(_, opts)
        composed = opts
      end,
      show_new_comment_input = function(_, opts)
        composed = opts
      end,
    }
  end)
  after_each(function()
    package.loaded["parley.discussion_window"], write._notify, write._confirm_delete = saved[1], saved[2], saved[3]
    contexts._entries[buf], providers._entries[buf], write._operations[buf] = nil, nil, nil
    reviews.detach(buf)
    composer.clear(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
  it("blocks composers and deletion confirmation before interaction", function()
    assert.is_false(write.open_new_comment_input(buf, { line = 1 }))
    assert.is_false(write.open_reply_input(buf, discussion, comment))
    assert.is_false(write.open_edit_input(buf, discussion, comment))
    assert.is_false(write.delete_comment(buf, nil, comment))
    assert.equals(0, confirms)
    assert.is_nil(composed)
    assert.equals(4, #notices)
  end)
  it("rechecks reply and edit capability at submission and preserves drafts", function()
    for _, method in ipairs({ "open_reply_input", "open_edit_input" }) do
      enabled = true
      write[method](buf, discussion, comment)
      assert.is_not_nil(composed)
      enabled = false
      local message
      assert.is_false(composed.on_submit({
        set_idle = function(text)
          message = text
        end,
      }, "keep my draft"))
      assert.matches("Draft preserved", message)
    end
    assert.equals(0, sent)
  end)
  it("does not ask the provider for reaction choices when disabled", function()
    p.reaction_choices = function()
      error("must not show choices")
    end
    local choices, reason = reactions.items(p, {}, comment)
    assert.same({}, choices)
    assert.equals("Unavailable in this provider", reason)
  end)
  it("rechecks review identity after drafting", function()
    enabled = true
    write.open_reply_input(buf, discussion, comment)
    providers._entries[buf] = { provider = {} }
    local message
    assert.is_false(composed.on_submit({
      set_idle = function(text)
        message = text
      end,
    }, "draft"))
    assert.matches("review changed", message)
    assert.equals(0, sent)
  end)
end)
