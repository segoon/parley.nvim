--- Versioned review keys derived solely from validated provider snapshots.
local digest = require("parley.cache_identity").digest
local M = {}

--- @param snapshot table
--- @param kind string
--- @param value string|integer
--- @return parley.CacheKey|nil
local function disk(snapshot, kind, value)
  if not snapshot.persistent then
    return nil
  end
  return { provider = "reviews-v2", repository = snapshot.scope, subkey = digest({ kind, tostring(value) }) }
end

--- @param snapshot table
--- @param branch string
--- @return parley.CacheKey|nil
function M.pr(snapshot, branch)
  return disk(snapshot, "branch", branch)
end

--- @param snapshot table
--- @param id string|integer
--- @return parley.CacheKey|nil
function M.discussions(snapshot, id)
  return disk(snapshot, "discussions", id)
end

--- @param snapshot table|nil
--- @param ctx table|nil
--- @return string|nil
function M.make(snapshot, ctx)
  local branch = ctx and ctx.vcs_info and ctx.vcs_info.branch
  if not snapshot or not snapshot.scope or not branch or branch == "" then
    return nil
  end
  return "reviews-v2/" .. snapshot.scope .. "/" .. digest({ "branch", branch })
end
return M
