--- parley.quickfix — populate the quickfix list with review discussions.

local entries = require("parley.discussion_entries")

local M = {}

--- @type fun(msg: string, level: integer): nil
M._notify = function(msg, level)
  vim.notify(msg, level)
end

--- @param items table[]
--- @param action string
--- @param opts table
M._setqflist = function(items, action, opts)
  local payload = vim.tbl_extend("force", opts or {}, { items = items })
  vim.fn.setqflist({}, action, payload)
end

M._copen = function()
  vim.cmd("copen")
end

--- @param bufnr integer
--- @return boolean
function M.open(bufnr)
  local state = require("parley.services.read").get_buffer_state(bufnr)
  if not state or not state.pr or not state.vcs_info or not state.vcs_info.root then
    M._notify("parley: no active PR discussions for this buffer", vim.log.levels.INFO)
    return false
  end

  local discussions = state.all_discussions or {}
  if #discussions == 0 then
    M._notify("parley: no discussions in the active review", vim.log.levels.INFO)
    return false
  end

  local items = {}
  local root = state.vcs_info.root
  local mappings = state.all_mappings or {}
  for _, discussion in ipairs(discussions) do
    if discussion.file and discussion.file ~= "" then
      local location = entries.location(discussion, root, mappings)
      items[#items + 1] = {
        filename = location.path,
        lnum = location.line,
        col = 1,
        text = location.text,
      }
    end
  end

  if #items == 0 then
    M._notify("parley: no discussions with file locations in the active review", vim.log.levels.INFO)
    return false
  end

  M._setqflist(items, "r", { title = "Parley Discussions" })
  M._copen()
  return true
end

return M
