--- Implemented plugin actions, independent of server-side token authorization.
local M = {}
--- @type parley.ProviderCapabilities
M.actions = {
  post_top_level_comment = { available = true },
  reply = { available = true },
  edit = { available = true },
  delete = { available = true },
  react = { available = true },
  submit_review = { available = true },
  resolve = { available = false, reason = "GitHub resolution requires GraphQL; not implemented in Parley" },
  unresolve = { available = false, reason = "GitHub reopening requires GraphQL; not implemented in Parley" },
}
--- @param _self parley.Provider
--- @param _review parley.DetectedReview
--- @return parley.ProviderCapabilities
function M.get(_self, _review)
  return vim.deepcopy(M.actions)
end
return M
