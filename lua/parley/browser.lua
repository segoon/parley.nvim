--- Open active review and discussion links in the system browser.
local read = require("parley.services.read")
local semantics = require("parley.discussion")
local ui = require("parley.ui_states.discussion")

local M = {}

--- @type fun(message: string, level: integer): nil
M._notify = function(message, level)
  vim.notify(message, level)
end

--- @type fun(url: string): vim.SystemObj|nil, nil|string
M._open = function(url)
  return vim.ui.open(url)
end

--- @param url string|nil
--- @param label "review"|"discussion"
--- @return boolean
local function open_url(url, label)
  if type(url) ~= "string" or not url:find("%S") then
    M._notify("parley: " .. label .. " link is unavailable", vim.log.levels.INFO)
    return false
  end

  local ok, handle, err = pcall(M._open, url)
  if not ok then
    err = handle
    handle = nil
  end
  if not handle then
    M._notify("parley: could not open " .. label .. ": " .. tostring(err or "unknown error"), vim.log.levels.WARN)
    return false
  end
  return true
end

--- Open the active review for `bufnr` in the system browser.
--- @param bufnr integer
--- @return boolean
function M.open_review(bufnr)
  local window = require("parley.discussion_window")
  bufnr = window.resolve_source_bufnr(bufnr)
  local snapshot = read.get_buffer_state(bufnr)
  if not snapshot or not snapshot.pr then
    M._notify("parley: no active review for this buffer", vim.log.levels.INFO)
    return false
  end
  return open_url(snapshot.pr.url, "review")
end

--- Open the selected discussion, or choose one at the source cursor line.
--- @param bufnr integer
--- @return boolean
function M.open_discussion(bufnr)
  local window = require("parley.discussion_window")
  bufnr = window.resolve_source_bufnr(bufnr)
  local discussion = window.current_discussion(bufnr)
  if discussion then
    return open_url(discussion.url, "discussion")
  end

  local selected_state = ui.get(bufnr)
  if selected_state and selected_state.current_discussion_id then
    M._notify("Selected discussion is no longer available; refresh the review", vim.log.levels.INFO)
    return false
  end

  local snapshot = read.get_buffer_state(bufnr)
  local expected_pr_id = snapshot and snapshot.pr and snapshot.pr.id or nil
  return window.open_current_line(bufnr, {
    on_select = function(chosen)
      local current = read.get_buffer_state(bufnr)
      if not current or not current.pr or current.pr.id ~= expected_pr_id then
        M._notify("Parley review changed; choose the discussion again", vim.log.levels.INFO)
        return false
      end
      local fresh = semantics.find(current, chosen.id)
      if not fresh then
        M._notify("Selected discussion is no longer available; refresh the review", vim.log.levels.INFO)
        return false
      end
      return open_url(fresh.url, "discussion")
    end,
  })
end

return M
