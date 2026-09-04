local write = require("parley.services.write")
local vcs = require("parley.vcs")
local contexts = require("parley.repositories.context")
local providers = require("parley.repositories.provider")
local reviews = require("parley.repositories.review")
local composer = require("parley.ui_states.composer")

describe("Arc new-comment validation", function()
  local saved, buf, compose, sent, notices, dirty, change_during_check
  before_each(function()
    vcs.reset_adapters()
    vcs.register_adapter("arc", require("parley.providers.vcs.arc"))
    saved = {
      runner = vcs._runner,
      window = package.loaded["parley.discussion_window"],
      notify = write._notify,
      refresh = write._refresh_context,
    }
    buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, "/tmp/parley-write-arc/f")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two" })
    vim.bo[buf].modified = false
    compose, dirty, change_during_check = nil, false, false
    sent, notices = 0, {}
    write._notify = function(message)
      notices[#notices + 1] = message
    end
    write._refresh_context = contexts.get
    vcs._runner = function(cmd)
      assert.equals("arc", cmd[1], "Arc writes must never invoke Git")
      if cmd[2] == "rev-parse" then
        return { code = 0, stdout = "abc\n" }
      end
      if cmd[2] == "status" then
        if change_during_check then
          vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "changed" })
        end
        return { code = 0, stdout = dirty and '{"status":{"staged":[{"path":"f"}]}}' or '{"status":{}}' }
      end
      return { code = 0, stdout = "@@ -1,2 +1,2 @@\n" }
    end
    contexts._entries[buf] = {
      kind = "regular",
      path = "/tmp/parley-write-arc/f",
      rel_path = "f",
      vcs_info = { vcs = "arc", root = "/tmp/parley-write-arc", branch = "users/a/feature" },
    }
    providers._entries[buf] = {
      provider = {
        begin_post_top_level_comment = function()
          sent = sent + 1
          return { cancel = function() end }
        end,
      },
    }
    reviews._seed(
      buf,
      { review = { pr = { id = "1", base_branch = "trunk" }, head_sha = "abc", write_context = { pr_id = 1 } } },
      "arc/write"
    )
    package.loaded["parley.discussion_window"] = {
      show_new_comment_input = function(_, opts)
        compose = opts
      end,
    }
  end)
  after_each(function()
    vcs.reset_adapters()
    vcs._runner, write._notify, write._refresh_context = saved.runner, saved.notify, saved.refresh
    package.loaded["parley.discussion_window"] = saved.window
    write._operations[buf], write._validating[buf] = nil, nil
    contexts._entries[buf], providers._entries[buf] = nil, nil
    reviews.detach(buf)
    composer.clear(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  --- @return table
  local function open()
    write.open_new_comment_input(buf, { line = 1 })
    assert.is_true(vim.wait(500, function()
      return compose ~= nil
    end))
    return { set_idle = function() end, set_submitting = function() end, set_cancel = function() end }
  end

  it("uses the shared revision without GitHub write_context fields", function()
    compose = nil
    local instance = open()
    compose.on_submit(instance, "comment")
    assert.is_true(vim.wait(500, function()
      return sent == 1
    end))
  end)

  it("rejects unsaved edits before opening a composer", function()
    vim.bo[buf].modified = true
    assert.is_false(write.open_new_comment_input(buf, { line = 1 }))
    assert.is_nil(compose)
    assert.is_truthy(notices[1]:find("unsaved", 1, true))
  end)

  it("preserves the draft when the file becomes dirty before submission", function()
    local instance = open()
    dirty = true
    compose.on_submit(instance, "preserve me")
    assert.is_true(vim.wait(500, function()
      return #notices > 0
    end))
    assert.equals(0, sent)
    assert.is_truthy(notices[1]:find("uncommitted", 1, true))
  end)

  it("rejects a branch switch while composing", function()
    local instance = open()
    contexts._entries[buf].vcs_info.branch = "another"
    compose.on_submit(instance, "comment")
    assert.is_true(vim.wait(500, function()
      return #notices > 0
    end))
    assert.equals(0, sent)
  end)

  it("rejects buffer edits during asynchronous validation", function()
    local instance = open()
    change_during_check = true
    compose.on_submit(instance, "comment")
    assert.is_true(vim.wait(500, function()
      return #notices > 0
    end))
    assert.equals(0, sent)
    assert.is_truthy(notices[1]:find("changed during", 1, true))
  end)
end)
