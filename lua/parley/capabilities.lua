--- Local provider action availability. Missing legacy metadata preserves existing actions.
local M = {}
--- @alias parley.ProviderAction 'post_top_level_comment'|'reply'|'edit'|'delete'|'react'
--- |'resolve'|'unresolve'|'submit_review'|'review_action'
--- @class parley.ActionCapability
--- @field available boolean
--- @field reason? string Required explanatory reason when unavailable.
--- @alias parley.ProviderCapabilities table<parley.ProviderAction, parley.ActionCapability>
--- @type parley.ProviderAction[]
M.actions = {
  "post_top_level_comment",
  "reply",
  "edit",
  "delete",
  "react",
  "resolve",
  "unresolve",
  "submit_review",
  "review_action",
}

--- @param provider parley.Provider|table
--- @param review parley.DetectedReview
--- @param action parley.ProviderAction
--- @return string|nil Unavailability reason; nil means allowed.
function M.reason(provider, review, action)
  local fallback = "This provider does not support " .. action .. " in Parley"
  if not provider then
    return "Parley provider context is unavailable"
  end
  if provider.capabilities == nil then
    return (action == "resolve" or action == "unresolve" or action == "review_action") and fallback or nil
  end
  local ok, values = pcall(provider.capabilities, provider, review)
  local value = ok and type(values) == "table" and values[action]
  if type(value) ~= "table" or type(value.available) ~= "boolean" then
    return "Provider capability information is unavailable for " .. action
  end
  if not value.available then
    return type(value.reason) == "string" and value.reason:find("%S") and value.reason or fallback
  end
end
return M
