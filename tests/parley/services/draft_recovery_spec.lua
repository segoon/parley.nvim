local contexts = require("parley.repositories.context")
local providers = require("parley.repositories.provider")
local reviews = require("parley.repositories.review")
local write = require("parley.services.write")
local window = require("parley.discussion_window")
local composer = require("parley.ui_states.composer")
local progress = require("parley.ui_states.progress")

describe("failed optimistic draft recovery", function()
  local buf, provider, saved, complete, notices, sends, before_buffers
  before_each(function()
    before_buffers = vim.api.nvim_list_bufs()
    buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".lua")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "source" })
    vim.bo[buf].modified = false
    local config = {
      float = { border = "rounded", max_width = 60, max_height = 15 },
      progress = {},
      virtual_text = { enabled = false },
      signs = { enabled = false },
    }
    saved = {
      config = require("parley").config,
      window_config = window._get_config,
      check = write._check_sync_state,
      refresh = write._refresh_context,
      defer = write._defer,
      notify = write._notify,
      background = reviews.refresh_async,
      invalidate = reviews.invalidate,
    }
    require("parley").config = config
    window._get_config = function()
      return config
    end
    write._check_sync_state = function()
      return { ok = true }
    end
    write._refresh_context = contexts.get
    write._defer = function() end
    reviews.refresh_async, reviews.invalidate = function() end, function() end
    complete, notices, sends = nil, {}, 0
    write._notify = function(message)
      notices[#notices + 1] = message
    end
    provider = require("parley.mock_provider").new({})
    provider.begin_post_top_level_comment = function(_, _, _, _, _, callback)
      sends, complete = sends + 1, callback
      return { cancel = function() end }
    end
    contexts.set(
      buf,
      { kind = "regular", rel_path = "a.lua", vcs_info = { vcs = "git", root = "/repo", branch = "feature" } }
    )
    providers._entries[buf] = { provider = provider, opts = { repository = "owner/repo" } }
    reviews._seed(buf, { review = { pr = { id = "42", base_branch = "main" }, head_sha = "head" } })
  end)
  after_each(function()
    for source in pairs(window._instances) do
      window.close(source)
    end
    write._operations[buf], write._validating[buf] = nil, nil
    contexts.invalidate(buf)
    providers.invalidate(buf)
    reviews.detach(buf)
    composer.clear(buf)
    progress.clear()
    require("parley").config, window._get_config = saved.config, saved.window_config
    write._check_sync_state, write._refresh_context = saved.check, saved.refresh
    write._defer, write._notify = saved.defer, saved.notify
    reviews.refresh_async, reviews.invalidate = saved.background, saved.invalidate
    for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
      if not vim.tbl_contains(before_buffers, candidate) then
        vim.api.nvim_buf_delete(candidate, { force = true })
      end
    end
  end)

  local function submit()
    write.open_new_comment_input(buf, { line = 1 })
    assert.is_true(vim.wait(500, function()
      return window._instances[buf] ~= nil
    end))
    local instance = window._instances[buf]
    vim.api.nvim_buf_set_lines(instance.input_bufnr, 0, -1, false, { "valuable draft" })
    instance.submit_input()
    assert.is_true(vim.wait(500, function()
      return complete ~= nil
    end))
  end

  for _, cancelled in ipairs({ false, true }) do
    it("restores a draft after source edits (cancelled=" .. tostring(cancelled) .. ")", function()
      submit()
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "edited while sending" })
      complete({ ok = false, cancelled = cancelled, err = "Rejected" })
      local instance = window._instances[buf]
      assert.is_not_nil(instance)
      assert.equals("idle", instance.input_state)
      assert.same({ "valuable draft" }, vim.api.nvim_buf_get_lines(instance.input_bufnr, 0, -1, false))
      local notice_count = #notices
      instance.submit_input()
      assert.is_true(vim.wait(500, function()
        return #notices > notice_count
      end))
      assert.equals(1, sends, "The restored draft still requires clean-file validation")
    end)
  end

  it("keeps the original review binding when restoring after a review switch", function()
    submit()
    reviews._seed(buf, { review = { pr = { id = "43", base_branch = "main" }, head_sha = "other" } })
    complete({ ok = false, err = "Rejected" })
    local instance = window._instances[buf]
    assert.is_not_nil(instance)
    assert.same({ "valuable draft" }, vim.api.nvim_buf_get_lines(instance.input_bufnr, 0, -1, false))
    instance.submit_input()
    assert.is_true(vim.wait(500, function()
      return #notices >= 2
    end))
    assert.equals(1, sends)
  end)

  it("retains a recoverable buffer if the source disappears before failure", function()
    submit()
    local alternate = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(vim.fn.bufwinid(buf), alternate)
    vim.api.nvim_buf_delete(buf, { force = true })
    assert.is_false(vim.api.nvim_buf_is_valid(buf))
    complete({ ok = false, err = "Rejected" })
    local recovered
    for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(candidate) and vim.bo[candidate].buflisted then
        local lines = vim.api.nvim_buf_get_lines(candidate, 0, -1, false)
        if lines[1] == "valuable draft" then
          recovered = candidate
        end
      end
    end
    assert.is_not_nil(recovered)
    assert.is_truthy(table.concat(notices, " "):find("buffer " .. recovered, 1, true))
  end)
  it("does not overwrite a newer draft when an earlier request fails", function()
    submit()
    write.open_new_comment_input(buf, { line = 1, initial_text = "newer draft" })
    assert.is_true(vim.wait(500, function()
      return composer.get(buf) and composer.get(buf).draft == "newer draft"
    end))
    complete({ ok = false, err = "Rejected" })
    local instance = window._instances[buf]
    assert.same({ "newer draft" }, vim.api.nvim_buf_get_lines(instance.input_bufnr, 0, -1, false))
    local recovered = false
    for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(candidate) and vim.bo[candidate].buflisted then
        recovered = recovered or vim.api.nvim_buf_get_lines(candidate, 0, 1, false)[1] == "valuable draft"
      end
    end
    assert.is_true(recovered)
  end)

  it("preserves a failed reply when its discussion disappears", function()
    local comment = {
      id = "1",
      author = "alice",
      body = { text = "Root", format = "markdown" },
      created_at = "",
      updated_at = "",
      reactions = {},
    }
    local discussion = { id = "1", file = "a.lua", line = 1, comments = { comment } }
    local snapshot = reviews.get(buf)
    snapshot.all_discussions, snapshot.discussions = { discussion }, { discussion }
    snapshot.mappings, snapshot.all_mappings = { ["1"] = { local_line = 1 } }, { ["1"] = { local_line = 1 } }
    reviews._seed(buf, snapshot)
    provider.begin_reply = function(_, _, _, _, _, callback)
      complete = callback
      return { cancel = function() end }
    end
    window.open_discussion(buf, "1")
    write.open_reply_input(buf, discussion, comment, { initial_text = "reply draft" })
    window._instances[buf].submit_input()
    assert.is_true(vim.wait(500, function()
      return complete ~= nil
    end))
    reviews._seed(buf, { review = { pr = { id = "43", base_branch = "main" }, head_sha = "other" } })
    complete({ ok = false, err = "Rejected" })
    local recovered = false
    for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(candidate) and vim.bo[candidate].buflisted then
        recovered = recovered or vim.api.nvim_buf_get_lines(candidate, 0, 1, false)[1] == "reply draft"
      end
    end
    assert.is_true(recovered)
  end)
end)
