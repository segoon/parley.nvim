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

  --- Register before calling provider code: completion may happen inline.
  --- @param bufnr integer
  --- @param operation table
  --- @param starter fun(callback: parley.WriteCallback): parley.CancelHandle
  --- @param on_complete parley.WriteCallback
  local function start_operation(bufnr, operation, starter, on_complete)
    local completed, cancel_requested, cancel_sent = false, false, false
    local request
    --- @return boolean
    local function active()
      return not completed and M._operations[bufnr] == operation
    end
    --- @param result any
    local function complete(result)
      if not active() then
        return
      end
      if
        type(result) ~= "table"
        or type(result.ok) ~= "boolean"
        or (result.cancelled ~= nil and type(result.cancelled) ~= "boolean")
        or (result.uncertain ~= nil and type(result.uncertain) ~= "boolean")
        or (result.err ~= nil and type(result.err) ~= "string")
        or (result.ok and result.cancelled)
      then
        result = { ok = false, err = "parley: provider returned an invalid write result" }
      end
      completed = true
      M._operations[bufnr] = nil
      on_complete(result)
    end
    --- Forward cancellation at most once, and only to this active request.
    local function cancel()
      if not active() or cancel_sent then
        return
      end
      cancel_requested = true
      if not request then
        return
      end
      cancel_sent = true
      local ok, err = pcall(request.cancel)
      if not ok then
        complete({ ok = false, err = "parley: cancellation failed: " .. tostring(err) })
      end
    end
    operation.cancel = cancel
    M._operations[bufnr] = operation
    if operation.input then
      operation.input.set_cancel(cancel)
    end
    local ok, result = pcall(starter, complete)
    if not active() then
      return
    end
    if not ok then
      complete({ ok = false, err = "parley: could not start request: " .. tostring(result) })
    elseif type(result) ~= "table" or type(result.cancel) ~= "function" then
      complete({ ok = false, err = "parley: provider returned an invalid cancellation handle" })
    else
      request = result
      if cancel_requested then
        cancel()
      end
    end
  end

  --- @param bufnr integer
  --- @param cursor_line integer|nil
  --- @param starter fun(
  ---   callback: parley.WriteCallback
  --- ): parley.CancelHandle
  --- @param progress_texts { running: string, refreshing: string, success: string, failed: string, cancelled: string }
  --- @return boolean
  --- @param opts? { preserve_selection?: boolean }
  local function run_action(bufnr, cursor_line, starter, progress_texts, opts)
    opts = opts or {}
    local function refresh_selected()
      if opts.preserve_selection and vim.api.nvim_buf_is_valid(bufnr) then
        local window = require("parley.discussion_window")
        window.refresh_snapshot(bufnr, review_repository.get(bufnr))
      end
    end
    if M._operations[bufnr] ~= nil then
      M._notify("Parley request already in progress for this buffer", vim.log.levels.WARN)
      return false
    end

    local progress = start_progress(bufnr, progress_texts.running)
    start_operation(bufnr, { progress = progress }, starter, function(result)
      if result.cancelled then
        if result.uncertain then
          M._notify(result.err or "Check the review before retrying.", vim.log.levels.WARN)
        end
        finish_progress(progress, bufnr, "cancelled", progress_texts.cancelled)
        refresh_after_write(bufnr, refresh_selected)
        return
      end

      if not result.ok then
        finish_progress(progress, bufnr, "failed", progress_texts.failed)
        M._notify(result.err or "parley: request failed", vim.log.levels.WARN)
        if result.uncertain then
          refresh_after_write(bufnr, refresh_selected)
        end
        return
      end

      update_progress(progress, bufnr, "running", progress_texts.refreshing)
      refresh_after_write(bufnr, function()
        finish_progress(progress, bufnr, "success", progress_texts.success)
        if opts.preserve_selection then
          refresh_selected()
        elseif vim.api.nvim_buf_is_valid(bufnr) then
          local discussion_window = require("parley.discussion_window")
          pcall(discussion_window.open_current_line, bufnr, { cursor_line = cursor_line })
        end
      end)
    end)

    return true
  end

  --- @param bufnr integer
  --- @param instance table
  --- @param starter fun(
  ---   callback: parley.WriteCallback
  --- ): parley.CancelHandle
  --- @param status_text string
  --- @param progress_texts { running: string, refreshing: string, success: string, failed: string, cancelled: string }
  --- @param success_opts? { cursor_line?: integer }
  local function run_submit(bufnr, instance, starter, status_text, progress_texts, success_opts)
    success_opts = success_opts or {}
    if M._operations[bufnr] ~= nil then
      M._notify("Parley request already in progress for this buffer", vim.log.levels.WARN)
      return false
    end

    local progress = start_progress(bufnr, progress_texts.running)
    composer_ui_state.patch(bufnr, { submit_state = "submitting", error = nil })
    instance.set_submitting(status_text)

    start_operation(bufnr, { progress = progress, input = instance }, starter, function(result)
      if result.cancelled then
        composer_ui_state.patch(bufnr, { submit_state = "idle" })
        instance.set_idle(
          (result.uncertain and (result.err or "Check the review before retrying.") or "Request cancelled.")
            .. " Draft preserved."
        )
        finish_progress(progress, bufnr, "cancelled", progress_texts.cancelled)
        refresh_after_write(bufnr, function() end)
        return
      end

      if not result.ok then
        composer_ui_state.patch(bufnr, { submit_state = "failed", error = result.err or "parley: request failed" })
        instance.set_idle(
          (result.uncertain and (result.err or "Check the review before retrying.") or "Request failed.")
            .. " Draft preserved."
        )
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
            if success_opts.discussion_id then
              pcall(discussion_window.open_discussion, bufnr, success_opts.discussion_id)
            else
              pcall(discussion_window.open_current_line, bufnr, { cursor_line = success_opts.cursor_line })
            end
          end
        end)
      end)
    end)

    return true
  end

  return { run_submit = run_submit, run_action = run_action }
end
