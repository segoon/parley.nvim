--- Built-in provider catalog and configuration-bound registration.
local M = {}

--- @class parley.ProviderDescriptor
--- @field id string
--- @field name string
--- @field defaults table
--- @field detect fun(info: parley.VcsInfo): table|nil
--- @field factory fun(opts: table, config: table): parley.Provider
--- @field health? fun(ctx: parley.HealthContext): parley.HealthEntry[]
--- @field initialize? fun()

--- @return parley.ProviderDescriptor[]
M._descriptors = function()
  return { require("parley.providers.github.descriptor"), require("parley.providers.arcanum.descriptor") }
end

--- @return table<string, table>
function M.defaults()
  local result = {}
  for _, descriptor in ipairs(M._descriptors()) do
    result[descriptor.id] = vim.deepcopy(descriptor.defaults)
  end
  return result
end

--- @param deps { registry: table, vcs: parley.VcsRegistrar }
--- @param config table<string, table>
function M.register(deps, config)
  require("parley.providers.vcs").register(deps.vcs)
  for _, descriptor in ipairs(M._descriptors()) do
    local settings =
      vim.tbl_deep_extend("force", vim.deepcopy(descriptor.defaults), vim.deepcopy(config[descriptor.id] or {}))
    if descriptor.initialize then
      descriptor.initialize()
    end
    deps.registry.register({
      name = descriptor.name,
      detect = descriptor.detect,
      health = descriptor.health,
      factory = function(opts)
        return descriptor.factory(opts, vim.deepcopy(settings))
      end,
    })
  end
end
return M
