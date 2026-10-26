--- GitHub CLI owns credential selection, including environment and secure storage.
local await = require("parley.runtime.await")
local M = {}

--- Resolve credentials asynchronously; never include CLI output in diagnostics.
--- Must run in a Plenary coroutine. The timeout also covers credential helpers.
--- @param host string
--- @param opts? { timeout_ms?: integer, system?: function, local_only?: boolean }
--- @return string|nil, string|nil
function M.read_token_async(host, opts)
  opts = opts or {}
  local cmd = { "gh", "auth", "token", "--hostname", host }
  if opts.local_only then
    cmd[#cmd + 1] = "--no-refresh"
  end
  local process_opts = {
    text = true,
    timeout = opts.timeout_ms or 5000,
    _system = opts.system,
  }
  local result = await.system(cmd, process_opts)
  -- Older gh releases do not refresh tokens and do not expose this flag.
  if opts.local_only and result.code ~= 0 and (result.stderr or ""):find("unknown flag: --no-refresh", 1, true) then
    table.remove(cmd)
    result = await.system(cmd, process_opts)
  end
  local token = result.code == 0 and (result.stdout or ""):match("^%s*(.-)%s*$") or nil
  if not token or token == "" then
    return nil, "GitHub credential unavailable; run gh auth login --hostname " .. host .. " and retry"
  end
  return token
end

return M
