--- GitHub-owned configuration and defaults.
local M = {}
--- @class parley.GitHubProviderConfig
--- @field timeout_ms integer
--- @field retry_count integer
--- @field retry_base_delay_ms integer
--- @field retry_max_delay_ms integer
local defaults = {
  timeout_ms = 5000,
  retry_count = 2,
  retry_base_delay_ms = 250,
  retry_max_delay_ms = 2000,
}
--- @param opts? table
--- @return parley.GitHubProviderConfig
function M.resolve(opts)
  return vim.tbl_deep_extend("force", vim.deepcopy(defaults), vim.deepcopy(opts or {}))
end
return M
