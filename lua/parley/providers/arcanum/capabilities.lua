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
  react = { available = false, reason = "Arcanum reaction changes are not implemented in Parley" },
  submit_review = { available = false, reason = "Arcanum review submission is not implemented in Parley" },
}
--- @param _self parley.Provider
--- @param _review parley.DetectedReview
--- @return parley.ProviderCapabilities
function M.get(_self, _review)
  return vim.deepcopy(M.actions)
end
return M
