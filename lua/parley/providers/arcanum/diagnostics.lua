--- Arcanum-specific local diagnostics. Never validates credentials over HTTP.
local M = {}
--- @type fun(name: string): integer
M._executable = vim.fn.executable
--- @type fun(): string|nil, string|nil
M._read_token = require("parley.providers.arcanum.auth").read_token_async

--- @param ctx parley.HealthContext
--- @return parley.HealthEntry[]
function M.check(ctx)
  local entries = {}
  for _, tool in ipairs({ "arc", "curl" }) do
    local found = M._executable(tool) == 1
    entries[#entries + 1] = {
      level = found and "ok" or "error",
      message = tool .. (found and " executable found" or " executable not found"),
    }
  end
  local branch = ctx.vcs_info.branch
  entries[#entries + 1] = {
    level = branch and branch ~= "" and "ok" or "warn",
    message = branch and branch ~= "" and ("Arc remote branch: " .. branch)
      or "Arc remote branch is unavailable; review detection needs a remote branch",
  }
  local login = ctx.opts.login
  entries[#entries + 1] = {
    level = login and login ~= "" and "ok" or "warn",
    message = login and login ~= "" and ("Arc login: " .. login) or "Arc user login is unavailable",
  }
  local token = M._read_token()
  entries[#entries + 1] = {
    level = token and "ok" or "warn",
    message = token and "Arcanum credential available locally"
      or "No Arcanum credential found: set ARCANUM_TOKEN or configure ~/.arc/token",
  }
  return entries
end
return M
