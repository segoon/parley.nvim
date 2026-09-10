--- Arcanum-specific local diagnostics. Never validates credentials over HTTP.
local config = require("parley.providers.arcanum.config")
local M = {}
--- @type fun(name: string): integer
M._executable = vim.fn.executable
--- @type fun(): string|nil, string|nil
M._read_token = require("parley.providers.arcanum.auth").read_token_async

--- @param ctx parley.HealthContext
--- @return parley.HealthEntry[]
function M.check(ctx)
  local settings = config.resolve(
    vim.tbl_extend(
      "force",
      (ctx.config and ctx.config.providers and ctx.config.providers.arcanum) or {},
      ctx.opts.host and { host = ctx.opts.host } or {}
    )
  )
  local entries = { { level = "ok", message = "Arcanum HTTPS host: " .. settings.host } }
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
    message = login and login ~= "" and ("Local Arc login (not verified API identity): " .. login)
      or "Arc user login is unavailable",
  }
  local token, err, source = M._read_token()
  entries[#entries + 1] = {
    level = token and "ok" or "warn",
    message = token and ("Arcanum credential available locally: " .. (source or "custom credential reader"))
      or err
      or "No Arcanum credential found: set ARCANUM_TOKEN, ARC_OAUTH_TOKEN, or ARC_TOKEN_PATH",
  }
  return entries
end
return M
