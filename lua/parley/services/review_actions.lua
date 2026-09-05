--- Execute confirmed review actions through the shared refresh/cancellation lifecycle.
local contexts = require("parley.services.write_context")
--- @param M table
--- @param operations table
return function(M, operations)
  --- @param bufnr integer
  --- @param action string
  --- @param expected table Captured before confirmation.
  --- @return boolean
  function M.review_action(bufnr, action, expected)
    local reason = contexts.reason(bufnr, "review_action", expected)
    if reason then
      M._notify(reason, vim.log.levels.INFO)
      return false
    end
    return operations.run_action(bufnr, nil, function(callback)
      local changed = contexts.reason(bufnr, "review_action", expected)
      if changed then
        callback({ ok = false, err = changed })
        return { cancel = function() end }
      end
      local current = contexts.get(bufnr)
      return current.provider:begin_review_action(expected.review, action, callback)
    end, {
      running = "Updating review",
      refreshing = "Refreshing review",
      success = "Review updated",
      failed = "Review update failed",
      cancelled = "Review update cancelled",
    }, { preserve_selection = true })
  end
end
