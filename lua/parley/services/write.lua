--- parley.services.write — Write-side discussion workflows.

local async = require("plenary.async")
local model = require("parley.model")
local vcs = require("parley.vcs")
local composer_ui_state = require("parley.ui_states.composer")
local progress_ui_state = require("parley.ui_states.progress")
local context_repository = require("parley.repositories.context")
local provider_repository = require("parley.repositories.provider")
local review_repository = require("parley.repositories.review")

local M = {}

--- Active write operations keyed by source buffer.
--- @type table<integer, { cancel: fun(): nil, input: table }>
M._operations = {}

--- Notify hook; replace in tests.
--- @type fun(msg: string, level: integer)
M._notify = function(msg, level)
  vim.notify(msg, level)
end

--- @type fun(cb: fun(), timeout: integer): nil
M._defer = function(cb, timeout)
  vim.defer_fn(cb, timeout)
end

--- @type fun(): integer
M._now = function()
  return math.floor((vim.uv or vim.loop).hrtime() / 1000000)
end

--- @type fun(): parley.Config|{ progress: parley.ProgressConfig }
M._get_config = function()
  return require("parley").config
end

--- @type fun(msg: string): boolean
M._confirm_delete = function(msg)
  return vim.fn.confirm(msg, "&Delete\n&Keep", 2) == 1
end

--- VCS sync-state check seam; replace in tests to avoid real git calls.
--- @type fun(root: string, rel_path: string, head_sha: string): { ok: boolean, err?: string }
M._check_sync_state = vcs.check_sync_state

M._next_progress_id = 0

--- @param bufnr integer
--- @return { provider: parley.Provider, review: parley.DetectedReview, rel_path: string }|nil, string|nil
local function resolve_write_context(bufnr)
  local review_snapshot = review_repository.get(bufnr)
  local provider_snapshot = provider_repository.get(bufnr)
  local context_snapshot = context_repository.get(bufnr)
  if not review_snapshot or not review_snapshot.review then
    return nil, "No Parley review is active for this buffer"
  end
  if not provider_snapshot or provider_snapshot.provider == nil then
    return nil, "Parley provider context is not ready for this buffer"
  end
  if not context_snapshot or type(context_snapshot.rel_path) ~= "string" or context_snapshot.rel_path == "" then
    return nil, "Parley file context is not ready for this buffer"
  end
  return {
    provider = provider_snapshot.provider,
    review = review_snapshot.review,
    rel_path = context_snapshot.rel_path,
    root = context_snapshot.vcs_info and context_snapshot.vcs_info.root or nil,
  },
    nil
end

--- @param line integer|nil
--- @param range integer|nil
--- @param line1 integer|nil
--- @param line2 integer|nil
--- @return parley.Anchor
local function resolve_anchor(line, range, line1, line2)
  if type(line) == "number" then
    return { start_line = line, end_line = nil }
  end

  if range and range > 0 and line1 and line2 then
    if line1 == line2 then
      return { start_line = line1, end_line = nil }
    end
    if line1 < line2 then
      return { start_line = line1, end_line = line2 }
    end
    return { start_line = line2, end_line = line1 }
  end

  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  return { start_line = cursor_line, end_line = nil }
end

--- @param message string|nil
local function notify_context_error(message)
  M._notify(message or "Parley write context is not ready for this buffer", vim.log.levels.WARN)
end

--- @param instance table
--- @param callback fun(): nil
local function close_input(instance, callback)
  instance.close(true)
  if callback then
    callback()
  end
end

--- @param bufnr integer
--- @param callback fun(snapshot: table|nil): nil
local function refresh_after_write(bufnr, callback)
  async.run(function()
    review_repository.invalidate(bufnr, { preserve_snapshot = true })
    local snapshot = review_repository.refresh(bufnr, { force = true })
    vim.schedule(function()
      callback(snapshot)
    end)
  end)
end

---@param state 'success'|'failed'|'cancelled'
---@return integer
local function progress_timeout(state)
  local config = M._get_config() or {}
  local progress = config.progress or {}
  if state == "success" then
    return progress.success_timeout or 1200
  end
  if state == "failed" then
    return progress.failed_timeout or 2500
  end
  return progress.cancelled_timeout or 1200
end

---@param bufnr integer
---@param message string
---@return { id: string, started_at: integer, title: string }
local function start_progress(bufnr, message)
  M._next_progress_id = M._next_progress_id + 1
  local entry = {
    id = tostring(M._next_progress_id),
    bufnr = bufnr,
    title = "Parley",
    message = message,
    kind = "write",
    state = "running",
    started_at = M._now(),
    updated_at = M._now(),
  }
  progress_ui_state.upsert(entry)
  return {
    id = entry.id,
    started_at = entry.started_at,
    title = entry.title,
  }
end

---@param progress { id: string, started_at: integer, title: string }
---@param bufnr integer
---@param state 'running'|'success'|'failed'|'cancelled'
---@param message string
local function update_progress(progress, bufnr, state, message)
  progress_ui_state.upsert({
    id = progress.id,
    bufnr = bufnr,
    title = progress.title,
    message = message,
    kind = "write",
    state = state,
    started_at = progress.started_at,
    updated_at = M._now(),
  })
end

---@param progress { id: string, started_at: integer, title: string }
---@param bufnr integer
---@param state 'success'|'failed'|'cancelled'
---@param message string
local function finish_progress(progress, bufnr, state, message)
  update_progress(progress, bufnr, state, message)
  M._defer(function()
    progress_ui_state.remove(progress.id)
  end, progress_timeout(state))
end

--- @param bufnr integer
--- @param cursor_line integer|nil
--- @param starter fun(
---   callback: fun(result: { ok: boolean, err?: string, cancelled?: boolean }): nil
--- ): { cancel: fun(): nil }
--- @param progress_texts { running: string, refreshing: string, success: string, failed: string, cancelled: string }
--- @return boolean
local function run_action(bufnr, cursor_line, starter, progress_texts)
  if M._operations[bufnr] ~= nil then
    M._notify("Parley request already in progress for this buffer", vim.log.levels.WARN)
    return false
  end

  local operation
  local progress = start_progress(bufnr, progress_texts.running)
  local request = starter(function(result)
    if M._operations[bufnr] ~= operation then
      return
    end

    M._operations[bufnr] = nil

    if result.cancelled then
      finish_progress(progress, bufnr, "cancelled", progress_texts.cancelled)
      refresh_after_write(bufnr, function() end)
      return
    end

    if not result.ok then
      finish_progress(progress, bufnr, "failed", progress_texts.failed)
      M._notify(result.err or "parley: request failed", vim.log.levels.WARN)
      return
    end

    update_progress(progress, bufnr, "running", progress_texts.refreshing)
    refresh_after_write(bufnr, function()
      finish_progress(progress, bufnr, "success", progress_texts.success)
      if vim.api.nvim_buf_is_valid(bufnr) then
        local discussion_window = require("parley.discussion_window")
        pcall(discussion_window.open_current_line, bufnr, { cursor_line = cursor_line })
      end
    end)
  end)

  operation = {
    cancel = request.cancel,
    progress = progress,
  }
  M._operations[bufnr] = operation
  return true
end

--- @param bufnr integer
--- @param instance table
--- @param starter fun(
---   callback: fun(result: { ok: boolean, comment?: parley.Comment, err?: string, cancelled?: boolean }): nil
--- ): { cancel: fun(): nil }
--- @param status_text string
--- @param progress_texts { running: string, refreshing: string, success: string, failed: string, cancelled: string }
--- @param success_opts? { cursor_line?: integer }
local function run_submit(bufnr, instance, starter, status_text, progress_texts, success_opts)
  success_opts = success_opts or {}
  if M._operations[bufnr] ~= nil then
    M._notify("Parley request already in progress for this buffer", vim.log.levels.WARN)
    return false
  end

  local operation
  local progress = start_progress(bufnr, progress_texts.running)
  composer_ui_state.patch(bufnr, { submit_state = "submitting", error = nil })
  instance.set_submitting(status_text)

  local request = starter(function(result)
    if M._operations[bufnr] ~= operation then
      return
    end

    M._operations[bufnr] = nil

    if result.cancelled then
      composer_ui_state.patch(bufnr, { submit_state = "idle" })
      instance.set_idle("Request cancelled. Draft preserved.")
      finish_progress(progress, bufnr, "cancelled", progress_texts.cancelled)
      refresh_after_write(bufnr, function() end)
      return
    end

    if not result.ok then
      composer_ui_state.patch(bufnr, { submit_state = "failed", error = result.err or "parley: request failed" })
      instance.set_idle("Request failed. Fix the draft and retry.")
      finish_progress(progress, bufnr, "failed", progress_texts.failed)
      M._notify(result.err or "parley: request failed", vim.log.levels.WARN)
      return
    end

    composer_ui_state.clear(bufnr)
    update_progress(progress, bufnr, "running", progress_texts.refreshing)
    close_input(instance, function()
      refresh_after_write(bufnr, function()
        finish_progress(progress, bufnr, "success", progress_texts.success)
        if vim.api.nvim_buf_is_valid(bufnr) then
          local discussion_window = require("parley.discussion_window")
          pcall(discussion_window.open_current_line, bufnr, { cursor_line = success_opts.cursor_line })
        end
      end)
    end)
  end)

  operation = {
    cancel = request.cancel,
    input = instance,
    progress = progress,
  }
  M._operations[bufnr] = operation
  instance.set_cancel(function()
    local active = M._operations[bufnr]
    if active ~= nil then
      active.cancel()
    end
  end)
  return true
end

--- Open an input window for a new top-level comment.
--- @param bufnr integer
--- @param opts? { line?: integer, range?: integer, line1?: integer, line2?: integer }
function M.open_new_comment_input(bufnr, opts)
  opts = opts or {}
  local write_context, err = resolve_write_context(bufnr)
  if not write_context then
    notify_context_error(err)
    return false
  end
  local anchor = resolve_anchor(opts.line, opts.range, opts.line1, opts.line2)
  local target_line = anchor.start_line

  async.run(function()
    local check = M._check_sync_state(
      write_context.root or "",
      write_context.rel_path,
      write_context.review.write_context.head_sha
    )
    if not check.ok then
      vim.schedule(function()
        M._notify(check.err, vim.log.levels.WARN)
      end)
      return
    end

    composer_ui_state.set(bufnr, {
      mode = "new",
      visible = true,
      submit_state = "idle",
      target_line = anchor,
      draft = "",
    })

    require("parley.discussion_window").show_new_comment_input(bufnr, {
      cursor_line = target_line,
      status = "Drafting top-level comment. Press <C-s> to send, or <Esc>s in normal mode. q closes.",
      on_submit = function(instance, text)
      local body = model.new_body({ text = text, format = "markdown" })
      return run_submit(
        bufnr,
        instance,
        function(callback)
          if write_context.provider.begin_post_top_level_comment then
            return write_context.provider:begin_post_top_level_comment(
              write_context.review,
              write_context.rel_path,
              anchor,
              body,
              callback
            )
          end

          local cancelled = false
          async.run(function()
            local ok, result = pcall(function()
              return write_context.provider:post_top_level_comment(
                write_context.review,
                write_context.rel_path,
                anchor,
                body
              )
            end)
            vim.schedule(function()
              if cancelled then
                callback({ ok = false, cancelled = true })
              elseif ok then
                callback({ ok = true, comment = result })
              else
                callback({ ok = false, err = tostring(result) })
              end
            end)
          end)
          return {
            cancel = function()
              cancelled = true
            end,
          }
        end,
        "Sending request... Press C to cancel request.",
        {
          running = "Sending comment",
          refreshing = "Refreshing discussion",
          success = "Comment sent",
          failed = "Comment failed",
          cancelled = "Comment cancelled",
        },
        { cursor_line = target_line }
      )
    end,
  })
  end)
end

--- Open an input window for a reply.
--- @param bufnr integer
--- @param discussion parley.Discussion|nil
--- @param parent_comment parley.Comment|nil
function M.open_reply_input(bufnr, discussion, parent_comment)
  if not discussion or not parent_comment then
    M._notify("Open a Parley discussion before replying", vim.log.levels.INFO)
    return false
  end
  local write_context, err = resolve_write_context(bufnr)
  if not write_context then
    notify_context_error(err)
    return false
  end
  local review_snapshot = review_repository.get(bufnr)
  local target_line = review_snapshot
      and review_snapshot.mappings
      and review_snapshot.mappings[discussion.id]
      and review_snapshot.mappings[discussion.id].local_line
    or nil
  composer_ui_state.set(bufnr, {
    mode = "reply",
    visible = true,
    submit_state = "idle",
    target_discussion_id = discussion.id,
    target_parent_comment_id = parent_comment.id,
    draft = "",
  })

  require("parley.discussion_window").show_reply_input(bufnr, {
    parent_comment_id = parent_comment.id,
    status = "Drafting reply. Press <C-s> to send, or <Esc>s in normal mode. q closes.",
    on_submit = function(instance, text)
      local body = model.new_body({ text = text, format = "markdown" })
      return run_submit(
        bufnr,
        instance,
        function(callback)
          if write_context.provider.begin_reply then
            return write_context.provider:begin_reply(write_context.review, discussion, parent_comment, body, callback)
          end

          local cancelled = false
          async.run(function()
            local ok, result = pcall(function()
              return write_context.provider:reply(write_context.review, discussion, parent_comment, body)
            end)
            vim.schedule(function()
              if cancelled then
                callback({ ok = false, cancelled = true })
              elseif ok then
                callback({ ok = true, comment = result })
              else
                callback({ ok = false, err = tostring(result) })
              end
            end)
          end)
          return {
            cancel = function()
              cancelled = true
            end,
          }
        end,
        "Sending request... Press C to cancel request.",
        {
          running = "Sending reply",
          refreshing = "Refreshing discussion",
          success = "Reply sent",
          failed = "Reply failed",
          cancelled = "Reply cancelled",
        },
        { cursor_line = target_line }
      )
    end,
  })
end

--- Open an input window for editing an existing comment.
--- @param bufnr integer
--- @param discussion parley.Discussion|nil
--- @param comment parley.Comment|nil
function M.open_edit_input(bufnr, discussion, comment)
  if not discussion or not comment then
    M._notify("Open a Parley discussion before editing", vim.log.levels.INFO)
    return false
  end
  local write_context, err = resolve_write_context(bufnr)
  if not write_context then
    notify_context_error(err)
    return false
  end
  local review_snapshot = review_repository.get(bufnr)
  local target_line = review_snapshot
      and review_snapshot.mappings
      and review_snapshot.mappings[discussion.id]
      and review_snapshot.mappings[discussion.id].local_line
    or nil
  composer_ui_state.set(bufnr, {
    mode = "edit",
    visible = true,
    submit_state = "idle",
    target_discussion_id = discussion.id,
    target_comment_id = comment.id,
    draft = comment.body.text,
  })

  require("parley.discussion_window").show_reply_input(bufnr, {
    parent_comment_id = comment.id,
    initial_text = comment.body.text,
    status = "Editing comment. Press <C-s> to save, or <Esc>s in normal mode. q closes.",
    on_submit = function(instance, text)
      local body = model.new_body({ text = text, format = "markdown" })
      return run_submit(
        bufnr,
        instance,
        function(callback)
          local cancelled = false
          async.run(function()
            local ok, result = pcall(function()
              return write_context.provider:edit(write_context.review, comment.id, body)
            end)
            vim.schedule(function()
              if cancelled then
                callback({ ok = false, cancelled = true })
              elseif ok then
                callback({ ok = true, comment = result })
              else
                callback({ ok = false, err = tostring(result) })
              end
            end)
          end)
          return {
            cancel = function()
              cancelled = true
            end,
          }
        end,
        "Saving edit... Press C to cancel request.",
        {
          running = "Saving edit",
          refreshing = "Refreshing discussion",
          success = "Comment updated",
          failed = "Edit failed",
          cancelled = "Edit cancelled",
        },
        { cursor_line = target_line }
      )
    end,
  })
end

--- Toggle a reaction on an existing comment and refresh the discussion.
--- @param bufnr integer
--- @param cursor_line integer|nil
--- @param comment parley.Comment|nil
--- @param reaction string
--- @return boolean
function M.react_comment(bufnr, cursor_line, comment, reaction)
  if not comment then
    M._notify("Open a Parley discussion before reacting", vim.log.levels.INFO)
    return false
  end
  local write_context, err = resolve_write_context(bufnr)
  if not write_context then
    notify_context_error(err)
    return false
  end
  return run_action(bufnr, cursor_line, function(callback)
    local cancelled = false
    async.run(function()
      local ok, result = pcall(function()
        write_context.provider:react(write_context.review, comment.id, reaction)
      end)
      vim.schedule(function()
        if cancelled then
          callback({ ok = false, cancelled = true })
        elseif ok then
          callback({ ok = true })
        else
          callback({ ok = false, err = tostring(result) })
        end
      end)
    end)
    return {
      cancel = function()
        cancelled = true
      end,
    }
  end, {
    running = "Updating reaction",
    refreshing = "Refreshing discussion",
    success = "Reaction updated",
    failed = "Reaction failed",
    cancelled = "Reaction cancelled",
  })
end

--- Delete an existing comment and refresh the discussion.
--- @param bufnr integer
--- @param cursor_line integer|nil
--- @param comment parley.Comment|nil
--- @return boolean
function M.delete_comment(bufnr, cursor_line, comment)
  if not comment then
    M._notify("Open a Parley discussion before deleting", vim.log.levels.INFO)
    return false
  end
  if not M._confirm_delete("Delete this comment permanently? This cannot be undone.") then
    return false
  end

  local write_context, err = resolve_write_context(bufnr)
  if not write_context then
    notify_context_error(err)
    return false
  end
  return run_action(bufnr, cursor_line, function(callback)
    local cancelled = false
    async.run(function()
      local ok, result = pcall(function()
        write_context.provider:delete(write_context.review, comment.id)
      end)
      vim.schedule(function()
        if cancelled then
          callback({ ok = false, cancelled = true })
        elseif ok then
          callback({ ok = true })
        else
          callback({ ok = false, err = tostring(result) })
        end
      end)
    end)
    return {
      cancel = function()
        cancelled = true
      end,
    }
  end, {
    running = "Deleting comment",
    refreshing = "Refreshing discussion",
    success = "Comment deleted",
    failed = "Delete failed",
    cancelled = "Delete cancelled",
  })
end

return M
