--- Shared progress/composer operation lifecycle.
local async = require("plenary.async")
local composer_ui_state = require("parley.ui_states.composer")
local progress_ui_state = require("parley.ui_states.progress")
local review_repository = require("parley.repositories.review")

--- @param M table Write service hooks and operations
--- @return table
return function(M)
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

  return { run_submit = run_submit, run_action = run_action }
end
