--- parley.services.write — Write-side discussion workflows.

local async = require("plenary.async")
local model = require("parley.model")
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

--- @param bufnr integer
--- @return parley.Provider, parley.PR, string
local function resolve_write_context(bufnr)
  local review_snapshot = review_repository.get(bufnr)
  local provider_snapshot = provider_repository.get(bufnr)
  local context_snapshot = context_repository.get(bufnr)
  assert(review_snapshot and review_snapshot.pr, "parley: no PR context available for this buffer")
  assert(
    provider_snapshot and provider_snapshot.provider ~= nil,
    "parley: provider context is not ready for this buffer"
  )
  assert(
    context_snapshot and type(context_snapshot.rel_path) == "string" and context_snapshot.rel_path ~= "",
    "parley: file context is not ready for this buffer"
  )
  return provider_snapshot.provider, review_snapshot.pr, context_snapshot.rel_path
end

--- @param line integer|nil
--- @param range integer|nil
--- @param line1 integer|nil
--- @param line2 integer|nil
--- @return parley.LineRange
local function resolve_line_range(line, range, line1, line2)
  if type(line) == "number" then
    assert(line > 0, "parley: line must be > 0")
    return line
  end

  if range and range > 0 and line1 and line2 then
    if line1 == line2 then
      return line1
    end
    if line1 < line2 then
      return { line1, line2 }
    end
    return { line2, line1 }
  end

  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  return cursor_line
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
--- @param callback fun(): nil
local function refresh_after_write(bufnr, callback)
  async.run(function()
    review_repository.invalidate(bufnr)
    review_repository.refresh(bufnr, { force = true })
    vim.schedule(callback)
  end)
end

--- @param bufnr integer
--- @param instance table
--- @param starter fun(callback: fun(result: { ok: boolean, comment?: parley.Comment, err?: string, cancelled?: boolean }): nil): { cancel: fun(): nil }
--- @param status_text string
--- @param success_opts? { cursor_line?: integer }
local function run_submit(bufnr, instance, starter, status_text, success_opts)
  success_opts = success_opts or {}
  if M._operations[bufnr] ~= nil then
    M._notify("Parley request already in progress for this buffer", vim.log.levels.WARN)
    return false
  end

  local operation
  M._notify("Parley: sending request...", vim.log.levels.INFO)
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
      refresh_after_write(bufnr, function() end)
      return
    end

    if not result.ok then
      composer_ui_state.patch(bufnr, { submit_state = "failed", error = result.err or "parley: request failed" })
      instance.set_idle("Request failed. Fix the draft and retry.")
      M._notify(result.err or "parley: request failed", vim.log.levels.WARN)
      return
    end

    composer_ui_state.clear(bufnr)
    refresh_after_write(bufnr, function()
      close_input(instance, function()
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
--- @param opts? { line?: parley.LineRange, range?: integer, line1?: integer, line2?: integer }
function M.open_new_comment_input(bufnr, opts)
  opts = opts or {}
  local provider, pr, rel_path = resolve_write_context(bufnr)
  local line = resolve_line_range(opts.line, opts.range, opts.line1, opts.line2)
  local target_line = type(line) == "table" and line[1] or line
  composer_ui_state.set(bufnr, {
    mode = "new",
    visible = true,
    submit_state = "idle",
    target_line = line,
    draft = "",
  })

  require("parley.discussion_window").show_new_comment_input(bufnr, {
    cursor_line = target_line,
    status = "Drafting top-level comment. Press <C-s> to send, or <Esc>s in normal mode. q closes.",
    on_submit = function(instance, text)
      local body = model.new_body({ text = text, format = "markdown" })
      return run_submit(bufnr, instance, function(callback)
        if provider.begin_post_top_level_comment then
          return provider:begin_post_top_level_comment(pr, rel_path, line, body, callback)
        end

        local cancelled = false
        async.run(function()
          local ok, result = pcall(function()
            return provider:post_top_level_comment(pr, rel_path, line, body)
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
      end, "Sending request... Press C to cancel request.", { cursor_line = target_line })
    end,
  })
end

--- Open an input window for a reply.
--- @param bufnr integer
--- @param discussion_id string
--- @param parent_comment_id string
function M.open_reply_input(bufnr, discussion_id, parent_comment_id)
  assert(type(parent_comment_id) == "string" and parent_comment_id ~= "", "parley: parent_comment_id is required")
  local provider, pr = resolve_write_context(bufnr)
  local review_snapshot = review_repository.get(bufnr)
  local target_line = review_snapshot
      and review_snapshot.mappings
      and review_snapshot.mappings[discussion_id]
      and review_snapshot.mappings[discussion_id].local_line
    or nil
  composer_ui_state.set(bufnr, {
    mode = "reply",
    visible = true,
    submit_state = "idle",
    target_discussion_id = discussion_id,
    target_parent_comment_id = parent_comment_id,
    draft = "",
  })

  require("parley.discussion_window").show_reply_input(bufnr, {
    parent_comment_id = parent_comment_id,
    status = "Drafting reply. Press <C-s> to send, or <Esc>s in normal mode. q closes.",
    on_submit = function(instance, text)
      local body = model.new_body({ text = text, format = "markdown" })
      return run_submit(bufnr, instance, function(callback)
        if provider.begin_reply then
          return provider:begin_reply(pr, discussion_id, parent_comment_id, body, callback)
        end

        local cancelled = false
        async.run(function()
          local ok, result = pcall(function()
            return provider:reply(pr, discussion_id, parent_comment_id, body)
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
      end, "Sending request... Press C to cancel request.", { cursor_line = target_line })
    end,
  })
end

return M
