--- parley.statusline — statusline component for PR review state.

local read_service = require("parley.services.read")

local M = {}

--- @type table<parley.ReviewStatus, string>
local REVIEW_STATUS_LABELS = {
  approved = "approved",
  changes_requested = "changes requested",
  pending = "pending",
  dismissed = "dismissed",
  commented = "commented",
}

--- @param state table
--- @return integer
local function unresolved_count(state)
  local summary = state.summary
  if summary and type(summary.unresolved_count) == "number" then
    return summary.unresolved_count
  end

  local count = 0
  for _, discussion in ipairs(state.discussions or {}) do
    if require("parley.model").is_open_issue(discussion) then
      count = count + 1
    end
  end
  return count
end

--- @param state table
--- @return string
local function pr_label(state)
  local provider = state.provider_display_name
  local prefix = provider and (provider .. " PR") or "PR"
  return string.format("%s #%s", prefix, state.pr.id)
end

--- Return a statusline string for `bufnr`, or an empty string when inactive.
--- Suitable for both lualine function components and `%!` statusline usage.
--- @param bufnr? integer
--- @return string
function M.component(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local state = read_service.get_buffer_state(bufnr)
  if not state or not state.pr then
    return ""
  end

  local unresolved = unresolved_count(state)
  local unresolved_label = string.format("%d unresolved", unresolved)
  local review_status = REVIEW_STATUS_LABELS[state.pr.review_status] or state.pr.review_status

  return string.format("%s · %s · %s", pr_label(state), review_status, unresolved_label)
end

return M
