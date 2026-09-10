--- Current write context and capability checks shared by composers and actions.
local contexts = require("parley.repositories.context")
local providers = require("parley.repositories.provider")
local reviews = require("parley.repositories.review")
local capabilities = require("parley.capabilities")
local M = {}
--- @param bufnr integer
--- @return table|nil, string|nil
function M.get(bufnr)
  local review, provider, context = reviews.get(bufnr), providers.get(bufnr), contexts.get(bufnr)
  if not review or not review.review then
    return nil, "No Parley review is active for this buffer"
  end
  if not provider or not provider.provider then
    return nil, "Parley provider context is not ready for this buffer"
  end
  if not context or type(context.rel_path) ~= "string" or context.rel_path == "" then
    return nil, "Parley file context is not ready for this buffer"
  end
  return {
    provider = provider.provider,
    identity_checked = provider.provider.cache_identity ~= nil,
    identity = provider.provider.cache_identity and vim.deepcopy(provider.provider:cache_identity()),
    review = review.review,
    rel_path = context.rel_path,
    vcs_info = vim.deepcopy(context.vcs_info),
  }
end
--- @param bufnr integer
--- @param action parley.ProviderAction
--- @param expected? table
--- @return string|nil
function M.reason(bufnr, action, expected)
  local current, err = M.get(bufnr)
  if not current then
    return err
  end
  if
    expected
    and (
      (expected.identity_checked and not vim.deep_equal(current.identity, expected.identity))
      or current.provider ~= expected.provider
      or current.review.pr.id ~= expected.review.pr.id
      or current.review.head_sha ~= expected.review.head_sha
    )
  then
    return "Parley review changed; reopen the action for the current review"
  end
  return capabilities.reason(current.provider, current.review, action)
end
return M
