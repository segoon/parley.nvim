--- Issue transitions validate the current root and capabilities at the mutation boundary.
local async = require("plenary.async")
local contexts = require("parley.services.write_context")
local reviews = require("parley.repositories.review")
local tree = require("parley.comment_tree")
local semantics = require("parley.discussion")

--- @param bufnr integer
--- @param id string
--- @param action 'resolve'|'unresolve'
--- @param expected? table
--- @return string|nil
local function reason(bufnr, id, action, expected)
  if action ~= "resolve" and action ~= "unresolve" then
    return "Unknown Parley issue action"
  end
  local unavailable = contexts.reason(bufnr, action, expected)
  if unavailable then
    return unavailable
  end
  local snapshot = reviews.get(bufnr)
  local discussion = snapshot and semantics.find(snapshot, id)
  if not discussion then
    return "Discussion is no longer available; refresh the review"
  end
  local _, _, ancestry = tree.order(discussion.comments)
  if discussion.ancestry or ancestry then
    return "Cannot change an issue with incomplete or cyclic ancestry; inspect it in the review"
  end
  local root, count = nil, 0
  for _, comment in ipairs(discussion.comments) do
    if not comment.parent_comment_id then
      root, count = comment, count + 1
    end
  end
  if count ~= 1 or root.id ~= id then
    return "Issue root is unavailable; inspect the thread in the review"
  end
  local state = semantics.issue_state(discussion)
  local required = action == "resolve" and "open" or "resolved"
  if state ~= required then
    return "Cannot " .. (action == "unresolve" and "reopen" or action) .. " this thread: issue state is " .. state
  end
end

--- @param M table Write service hooks
--- @param operations table
return function(M, operations)
  --- @param bufnr integer
  --- @param id string Root discussion ID, never the selected reply ID.
  --- @param action 'resolve'|'unresolve'
  --- @return boolean
  function M.set_issue_state(bufnr, id, action)
    local unavailable = reason(bufnr, id, action)
    if unavailable then
      M._notify(unavailable, vim.log.levels.INFO)
      return false
    end
    local context = contexts.get(bufnr)
    local label = action == "resolve" and "Resolving issue" or "Reopening issue"
    return operations.run_action(bufnr, nil, function(callback)
      local err = reason(bufnr, id, action, context)
      if err then
        callback({ ok = false, err = err })
        return { cancel = function() end }
      end
      local provider = context.provider
      local begin = provider["begin_" .. action]
      if begin then
        return begin(provider, context.review, id, callback)
      end
      local cancelled = false
      async.run(function()
        local ok, result = pcall(provider[action], provider, context.review, id)
        vim.schedule(function()
          callback({
            ok = ok and not cancelled,
            cancelled = cancelled,
            uncertain = cancelled,
            err = cancelled and "Issue update may have been sent; check the review before retrying"
              or not ok and tostring(result)
              or nil,
          })
        end)
      end)
      return {
        cancel = function()
          cancelled = true
        end,
      }
    end, {
      running = label,
      refreshing = "Refreshing issue",
      success = "Issue updated",
      failed = "Issue update failed",
      cancelled = "Issue update cancelled",
    }, { preserve_selection = true })
  end
end
