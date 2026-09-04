--- Built-in VCS composition. Concrete behavior and precedence live here.
local M = {}

--- @class parley.VcsRegistrar
--- @field register_adapter fun(name: string, adapter: parley.VcsAdapter)
--- @field register_detector fun(name: string, detector: fun(path: string): parley.VcsInfo|nil)

--- @param vcs parley.VcsRegistrar
function M.register(vcs)
  -- Arc must win when a checkout also contains Git metadata.
  vcs.register_adapter("arc", require("parley.providers.vcs.arc"))
  vcs.register_detector("arc", require("parley.providers.arcanum.vcs_detector").detect)
  vcs.register_adapter("git", require("parley.providers.vcs.git"))
  vcs.register_detector("git", require("parley.providers.github.vcs_detector").detect)
end

return M
