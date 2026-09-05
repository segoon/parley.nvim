--- parley.services.write — Write-side discussion workflows.

local async = require("plenary.async")
local model = require("parley.model")
local vcs = require("parley.vcs")
local composer_ui_state = require("parley.ui_states.composer")
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

--- VCS sync-state check seam; replace in tests to avoid real VCS calls.
--- @type fun(info: parley.VcsInfo, rel_path: string, head_sha: string): { ok: boolean, err?: string }
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
    vcs_info = vim.deepcopy(context_snapshot.vcs_info),
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

local operations = require("parley.services.write_operation")(M)

--- @type fun(bufnr: integer): table|nil
M._refresh_context = context_repository.refresh
--- @type table<integer, boolean>
M._validating = {}

--- Invoke provider eligibility and fail closed on contract errors.
--- @param context table
--- @param anch parley.Anchor
--- @return string|nil
local function validate_target(context, anch)
  local ok, result = pcall(
    context.provider.validate_comment_target,
    context.provider,
    context.review,
    { vcs_info = context.vcs_info, rel_path = context.rel_path, anchor = anch }
  )
  if not ok then
    return "Cannot comment: " .. tostring(result)
  end
  if
    type(result) ~= "table"
    or type(result.ok) ~= "boolean"
    or (not result.ok and (type(result.err) ~= "string" or not result.err:find("%S")))
  then
    return "Cannot comment: provider returned an invalid target validation result."
  end
  if not result.ok then
    return result.err
  end
end

--- @param bufnr integer
--- @param expected table
--- @return boolean
local function provider_changed(bufnr, expected)
  local snapshot = provider_repository.get(bufnr)
  return not snapshot or snapshot.provider ~= expected.provider
end

--- @param bufnr integer
--- @param expected table
--- @param anch parley.Anchor
--- @return string|nil
local function validate_submission(bufnr, expected, anch)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return "Source buffer is no longer available"
  end
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local current = M._refresh_context(bufnr)
  if
    not current
    or current.rel_path ~= expected.rel_path
    or not vim.deep_equal(current.vcs_info, expected.vcs_info)
  then
    return "Cannot comment: repository context changed. Reopen the draft for the current review."
  end
  local snapshot = review_repository.get(bufnr)
  if
    not snapshot
    or not snapshot.review
    or snapshot.review.head_sha ~= expected.review.head_sha
    or snapshot.review.pr.id ~= expected.review.pr.id
    or snapshot.review.pr.base_branch ~= expected.review.pr.base_branch
  then
    return "Cannot comment: review changed. Refresh and reopen the draft."
  end
  if vim.bo[bufnr].modified then
    return "Cannot comment: source buffer has unsaved changes."
  end
  local check = M._check_sync_state(expected.vcs_info, expected.rel_path, expected.review.head_sha)
  if not check.ok then
    return check.err
  end
  local target_error = validate_target(expected, anch)
  if target_error then
    return target_error
  end
  if provider_changed(bufnr, expected) then
    return "Cannot comment: provider context changed. Reopen the draft."
  end
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.api.nvim_buf_get_changedtick(bufnr) ~= tick then
    return "Cannot comment: source buffer changed during validation. Retry after saving."
  end
  current = context_repository.get(bufnr)
  snapshot = review_repository.get(bufnr)
  if
    not current
    or not vim.deep_equal(current.vcs_info, expected.vcs_info)
    or not snapshot
    or not snapshot.review
    or snapshot.review.head_sha ~= expected.review.head_sha
    or snapshot.review.pr.id ~= expected.review.pr.id
    or snapshot.review.pr.base_branch ~= expected.review.pr.base_branch
    or current.rel_path ~= expected.rel_path
  then
    return "Cannot comment: review context changed during validation. Reopen the draft."
  end
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
  if vim.bo[bufnr].modified then
    notify_context_error("Cannot comment: source buffer has unsaved changes.")
    return false
  end
  local source_tick = vim.api.nvim_buf_get_changedtick(bufnr)
  async.run(function()
    local check = M._check_sync_state(write_context.vcs_info, write_context.rel_path, write_context.review.head_sha)
    if not check.ok then
      vim.schedule(function()
        M._notify(check.err, vim.log.levels.WARN)
      end)
      return
    end

    local target_error = validate_target(write_context, anchor)
    if not target_error and provider_changed(bufnr, write_context) then
      target_error = "Cannot comment: provider context changed. Reopen the draft."
    end
    if target_error then
      notify_context_error(target_error)
      return
    end

    local current = context_repository.get(bufnr)
    local snapshot = review_repository.get(bufnr)
    if
      not current
      or current.rel_path ~= write_context.rel_path
      or not vim.deep_equal(current.vcs_info, write_context.vcs_info)
      or not snapshot
      or not snapshot.review
      or snapshot.review.head_sha ~= write_context.review.head_sha
      or snapshot.review.pr.id ~= write_context.review.pr.id
      or snapshot.review.pr.base_branch ~= write_context.review.pr.base_branch
    then
      notify_context_error("Cannot comment: review context changed during validation. Reopen the draft.")
      return
    end

    if not vim.api.nvim_buf_is_valid(bufnr) or vim.api.nvim_buf_get_changedtick(bufnr) ~= source_tick then
      notify_context_error("Cannot comment: source buffer changed during validation. Retry after saving.")
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
        if M._validating[bufnr] or M._operations[bufnr] then
          return false
        end
        M._validating[bufnr] = true
        async.run(function()
          local validation_ok, validation_err = pcall(validate_submission, bufnr, write_context, anchor)
          M._validating[bufnr] = nil
          if not validation_ok or validation_err then
            local message = tostring(validation_err)
            instance.set_idle(message .. " Draft preserved.")
            M._notify(message, vim.log.levels.WARN)
            return
          end
          local body = model.new_body({ text = text, format = "markdown" })
          operations.run_submit(
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
        end)
        return true
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
      return operations.run_submit(
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
        { cursor_line = target_line, discussion_id = discussion.id }
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
      return operations.run_submit(
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
        { cursor_line = target_line, discussion_id = discussion.id }
      )
    end,
  })
end

--- Toggle a reaction on an existing comment and refresh the discussion.
--- @param bufnr integer
--- @param cursor_line integer|nil
--- @param comment parley.Comment|nil
--- @param reaction string
--- @param expected? table Captured picker context
--- @return boolean
function M.react_comment(bufnr, cursor_line, comment, reaction, expected)
  if not comment then
    M._notify("Open a Parley discussion before reacting", vim.log.levels.INFO)
    return false
  end
  local write_context, err = resolve_write_context(bufnr)
  if not write_context then
    notify_context_error(err)
    return false
  end
  local reaction_error = require("parley.reactions").validate(bufnr, comment, reaction, expected)
  if reaction_error then
    M._notify(reaction_error, vim.log.levels.INFO)
    return false
  end
  return operations.run_action(bufnr, cursor_line, function(callback)
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
  return operations.run_action(bufnr, cursor_line, function(callback)
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
