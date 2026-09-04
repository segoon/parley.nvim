--- Arcanum registration descriptor; concrete composition stays provider-owned.
local M = {
  id = "arcanum",
  name = require("parley.providers.arcanum.metadata").display_name,
  defaults = require("parley.providers.arcanum.config").resolve(),
}
--- @param info parley.VcsInfo
--- @return table|nil
function M.detect(info)
  return require("parley.providers.arcanum.provider").detect(info)
end
--- @param opts table
--- @param config table
--- @return parley.Provider
function M.factory(opts, config)
  return require("parley.providers.arcanum.provider").new(vim.tbl_extend("force", opts, { config = config }))
end
--- @param ctx parley.HealthContext
--- @return parley.HealthEntry[]
function M.health(ctx)
  return require("parley.providers.arcanum.diagnostics").check(ctx)
end
return M
