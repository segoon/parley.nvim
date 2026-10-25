--- GitHub-specific local diagnostics. Never validates credentials over HTTP.
local M = {}
--- @type fun(name: string): integer
M._executable = vim.fn.executable
--- @type fun(host: string, opts: table): string|nil, string|nil
M._read_token = require("parley.providers.github.auth").read_token_async

--- @param ctx parley.HealthContext
--- @return parley.HealthEntry[]
function M.check(ctx)
  local entries = {}
  for _, tool in ipairs({ "git", "gh" }) do
    local found = M._executable(tool) == 1
    entries[#entries + 1] = {
      level = found and "ok" or "error",
      message = tool .. (found and " executable found" or " executable not found"),
    }
  end
  local branch = ctx.vcs_info.branch
  entries[#entries + 1] = {
    level = branch and branch ~= "" and "ok" or "info",
    message = branch and branch ~= "" and ("Current branch: " .. branch) or "No active branch (possibly detached HEAD)",
  }
  local token = M._read_token(ctx.opts.host, { local_only = true })
  entries[#entries + 1] = {
    level = token and "ok" or "warn",
    message = token and "GitHub credential available locally"
      or "GitHub credential unavailable; run gh auth login --hostname " .. ctx.opts.host .. " and retry",
  }
  return entries
end
return M
