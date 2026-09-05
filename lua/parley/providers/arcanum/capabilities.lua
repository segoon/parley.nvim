--- Implemented plugin actions, independent of server-side token authorization.
local M = {}
--- @type parley.ProviderCapabilities
M.actions = {
  post_top_level_comment = { available = true },
  reply = { available = true },
  edit = { available = true },
  delete = { available = true },
  resolve = { available = true },
  unresolve = { available = true },
  react = { available = true },
  review_action = { available = true },
  submit_review = { available = false, reason = "Use :Parley review actions; review messages are unsupported" },
}
--- @param self parley.Provider
--- @param review parley.DetectedReview
--- @return parley.ProviderCapabilities
function M.get(self, review)
  local actions = vim.deepcopy(M.actions)
  local choices, reason = require("parley.providers.arcanum.review_actions").choices(self, review)
  if #choices == 0 then
    actions.review_action = { available = false, reason = reason }
  end
  return actions
end
return M
