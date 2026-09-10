--- GitHub owns host, repository, and local credential-context identity.
---
--- This must produce a consistent fingerprint whether called from inside a
--- plenary.async coroutine or outside one (write_context captures it
--- synchronously, then re-checks it inside async.run before submitting), so
--- it only uses coroutine-free I/O: the sync token reader and _sync_runner.
local M = {}

--- @param self parley.github.Provider
--- @return parley.CacheIdentity|nil
function M.get(self)
  local ok, token = pcall(self._auth.read_token, self._host)
  if not ok or not token or token == "" then
    local runner = self._sync_runner or self._runner
    local ran, result = pcall(runner, { "gh", "auth", "token", "--hostname", self._host })
    token = ran and result and result.code == 0 and (result.stdout or ""):match("^%s*(.-)%s*$") or nil
  end
  if not token or token == "" then
    return nil
  end
  local runner = self._sync_runner or self._runner
  local ran, result = pcall(runner, { "gh", "config", "get", "-h", self._host, "user" })
  local login = ran and result and result.code == 0 and (result.stdout or ""):match("^%s*(.-)%s*$") or ""
  return {
    provider = "github",
    host = self._host .. "\0" .. self._api_base,
    repository = self._owner .. "/" .. self._repo,
    account = vim.fn.sha256(vim.json.encode({ token, login })),
  }
end
return M
