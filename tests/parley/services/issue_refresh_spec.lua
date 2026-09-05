local write = require("parley.services.write")
local reviews = require("parley.repositories.review")
local contexts = require("parley.repositories.context")
local providers = require("parley.repositories.provider")
local window = require("parley.discussion_window")
local ui = require("parley.ui_states.discussion")
local model = require("parley.model")
local progress = require("parley.ui_states.progress")

describe("issue refresh with an active general-discussion draft", function()
  local saved, buf, snapshot, complete, refreshes, notices
  before_each(function()
    saved = { reviews.refresh, reviews.invalidate, write._defer, write._notify }
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    refreshes, notices = 0, {}
    local d = model.new_discussion({
      id = "42",
      anchor = { kind = "general" },
      issue_state = "open",
      comments = {
        model.new_comment({
          id = "42",
          author = "a",
          body = { text = "issue", format = "markdown" },
          created_at = "",
          updated_at = "",
          is_own = true,
        }),
      },
    })
    snapshot = { review = { pr = { id = "1" }, head_sha = "head" }, all_discussions = { d } }
    reviews._seed(buf, snapshot, "issue-refresh")
    contexts._entries[buf] = { rel_path = "f", vcs_info = { root = "/repo", vcs = "arc" } }
    providers._entries[buf] = {
      provider = {
        capabilities = function()
          return { resolve = { available = true }, unresolve = { available = true } }
        end,
        begin_resolve = function(_, _, id, cb)
          assert.equals("42", id)
          complete = cb
          return { cancel = function() end }
        end,
        begin_unresolve = function(_, _, id, cb)
          assert.equals("42", id)
          complete = cb
          return { cancel = function() end }
        end,
      },
    }
    reviews.invalidate = function() end
    reviews.refresh = function()
      refreshes = refreshes + 1
      reviews._seed(buf, snapshot, "issue-refresh")
      return reviews.get(buf)
    end
    write._defer = function() end
    write._notify = function(message)
      notices[#notices + 1] = message
    end
    assert.is_true(window.open_discussion(buf, "42"))
    window.show_reply_input(buf, { parent_comment_id = "42", status = "Reply draft", on_submit = function() end })
    vim.api.nvim_buf_set_lines(window._instances[buf].input_bufnr, 0, -1, false, { "unsent reply" })
  end)
  after_each(function()
    reviews.refresh, reviews.invalidate, write._defer, write._notify = saved[1], saved[2], saved[3], saved[4]
    window.close(buf)
    reviews.detach(buf)
    contexts._entries[buf], providers._entries[buf], write._operations[buf] = nil, nil, nil
    progress.clear()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
  it("refreshes issue counts and title in place after both transitions", function()
    local instance = window._instances[buf]
    local winid, input = instance.winid, instance.input_bufnr
    for _, action in ipairs({ "resolve", "unresolve" }) do
      local previous_count = action == "resolve" and 1 or 0
      assert.is_true(write.set_issue_state(buf, "42", action))
      assert.equals(previous_count, reviews.get(buf).summary.unresolved_count)
      snapshot.all_discussions[1].issue_state = action == "resolve" and "resolved" or "open"
      complete({ ok = true })
      local expected = action == "resolve" and 1 or 2
      local expected_title = (action == "resolve" and "resolved" or "unresolved") .. " · general"
      assert.is_true(vim.wait(300, function()
        return refreshes == expected
          and write._operations[buf] == nil
          and vim.api.nvim_win_get_config(winid).title[1][1] == expected_title
      end))
      assert.equals(action == "resolve" and 0 or 1, reviews.get(buf).summary.unresolved_count)
      local title = vim.api.nvim_win_get_config(winid).title[1][1]
      assert.equals((action == "resolve" and "resolved" or "unresolved") .. " · general", title)
      assert.equals(winid, window._instances[buf].winid)
      assert.equals("42", ui.get(buf).current_discussion_id)
      assert.equals("42", ui.get(buf).selected_comment_id)
      assert.same({ "unsent reply" }, vim.api.nvim_buf_get_lines(input, 0, -1, false))
    end
  end)
  it("refreshes uncertain outcomes without clearing the draft or claiming success", function()
    assert.is_true(write.set_issue_state(buf, "42", "resolve"))
    complete({ ok = false, uncertain = true, err = "Check the review before retrying" })
    assert.is_true(vim.wait(300, function()
      return refreshes == 1
    end))
    assert.equals("Check the review before retrying", notices[1])
    assert.equals(1, reviews.get(buf).summary.unresolved_count)
    assert.same({ "unsent reply" }, vim.api.nvim_buf_get_lines(window._instances[buf].input_bufnr, 0, -1, false))
  end)
end)
