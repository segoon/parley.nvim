--- Select an issue using the same source-line picker as discussion opening.
local contexts = require("parley.services.write_context")
local ui = require("parley.ui_states.discussion")
local M = {}
--- @param bufnr integer
--- @param action 'resolve'|'unresolve'
--- @return boolean
function M.run(bufnr, action)
  local window = require("parley.discussion_window")
  local write = require("parley.services.write")
  bufnr = window.resolve_source_bufnr(bufnr)
  local reason = contexts.reason(bufnr, action)
  if reason then
    write._notify(reason, vim.log.levels.INFO)
    return false
  end
  local expected = contexts.get(bufnr)
  --- @param discussion parley.Discussion
  --- @return boolean
  local function selected(discussion)
    local changed = contexts.reason(bufnr, action, expected)
    if changed then
      write._notify(changed, vim.log.levels.INFO)
      return false
    end
    return write.set_issue_state(bufnr, discussion.id, action)
  end
  local discussion = window.current_discussion(bufnr)
  if discussion then
    return selected(discussion)
  end
  local state = ui.get(bufnr)
  if state and state.current_discussion_id then
    write._notify("Selected discussion is no longer available; refresh the review", vim.log.levels.INFO)
    return false
  end
  return window.open_current_line(bufnr, { on_select = selected })
end
return M
