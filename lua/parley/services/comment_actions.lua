--- Existing comment actions, gated before choices and mutations.
local async = require("plenary.async")
--- @param M table Write service hooks
--- @param operations table
--- @param resolve_write_context function
--- @param notify_context_error function
--- @param allowed function
return function(M, operations, resolve_write_context, notify_context_error, allowed)
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
    if not allowed(bufnr, "react", write_context) then
      return false
    end
    local reaction_error = require("parley.reactions").validate(bufnr, comment, reaction, expected)
    if reaction_error then
      M._notify(reaction_error, vim.log.levels.INFO)
      return false
    end
    return operations.run_action(bufnr, cursor_line, function(callback)
      if write_context.provider.begin_set_reaction then
        local reason = require("parley.reactions").validate(bufnr, comment, reaction, expected)
        if reason then
          callback({ ok = false, err = reason })
          return { cancel = function() end }
        end
        local present = expected and expected.present
        if present == nil then
          present = true
          for _, state in ipairs(comment.reactions or {}) do
            if state.type == reaction and state.viewer_reacted then
              present = false
            end
          end
        end
        return write_context.provider:begin_set_reaction(write_context.review, comment.id, reaction, present, callback)
      end
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
    }, { preserve_selection = true })
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
    local write_context, err = resolve_write_context(bufnr)
    if not write_context then
      notify_context_error(err)
      return false
    end
    if not allowed(bufnr, "delete", write_context) then
      return false
    end
    if not M._confirm_delete("Delete this comment permanently? This cannot be undone.") then
      return false
    end
    if not allowed(bufnr, "delete", write_context) then
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
end
