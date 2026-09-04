--- Identity of shared remote review data, independent of local projections.
local M = {}

--- @param provider parley.Provider
--- @return string
local function provider_name(provider)
  return provider._cache_provider or "github"
end

--- @param provider parley.Provider
--- @param opts table
--- @param branch string
--- @return table
local function pr_cache_key(provider, opts, branch)
  return {
    provider = provider_name(provider),
    repository = opts.repository,
    subkey = "pr_branch_" .. branch,
  }
end

--- @param provider parley.Provider
--- @param opts table
--- @param pr_id string|integer
--- @return table
local function discussions_cache_key(provider, opts, pr_id)
  return {
    provider = provider_name(provider),
    repository = opts.repository,
    subkey = "discussions_" .. pr_id,
  }
end

--- @param provider_snapshot table|nil
--- @param ctx table|nil
--- @return string|nil
function M.make(provider_snapshot, ctx)
  if not provider_snapshot or not provider_snapshot.provider or not provider_snapshot.opts then
    return nil
  end
  if not ctx or not ctx.vcs_info or not ctx.vcs_info.branch or ctx.vcs_info.branch == "" then
    return nil
  end
  local name = provider_name(provider_snapshot.provider)
  local opts = provider_snapshot.opts
  return name .. "/" .. opts.repository .. "/" .. ctx.vcs_info.branch
end
M.pr = pr_cache_key
M.discussions = discussions_cache_key
return M
