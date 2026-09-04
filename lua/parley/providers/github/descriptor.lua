--- GitHub registration descriptor; concrete composition stays provider-owned.
local M = { id = "github", name = "GitHub", defaults = require("parley.providers.github.config").resolve() }
--- @param info parley.VcsInfo
--- @return table|nil
function M.detect(info)
  return require("parley.providers.github.provider").detect(info)
end
--- @param opts table
--- @param config table
--- @return parley.Provider
function M.factory(opts, config)
  return require("parley.providers.github.provider").new(vim.tbl_extend("force", opts, { config = config }))
end
--- @param ctx parley.HealthContext
--- @return parley.HealthEntry[]
function M.health(ctx)
  return require("parley.providers.github.diagnostics").check(ctx)
end
function M.initialize()
  require("parley.providers.github.transport").probe_gh_executable()
end
return M
