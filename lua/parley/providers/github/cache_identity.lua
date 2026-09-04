--- GitHub owns host, repository, and local credential-context identity.
local M = {}

--- @param self parley.github.Provider
--- @return parley.CacheIdentity|nil
function M.get(self)
  local reader = self._auth.read_token_async or self._auth.read_token
  local ok, token = pcall(reader, self._host)
  if not ok or not token or token == "" then
    local ran, result = pcall(self._runner, { "gh", "auth", "token", "--hostname", self._host })
    token = ran and result and result.code == 0 and (result.stdout or ""):match("^%s*(.-)%s*$") or nil
  end
  if not token or token == "" then
    return nil
  end
  local ran, result = pcall(self._runner, { "gh", "config", "get", "-h", self._host, "user" })
  local login = ran and result and result.code == 0 and (result.stdout or ""):match("^%s*(.-)%s*$") or ""
  return {
    provider = "github",
    host = self._host .. "\0" .. self._api_base,
    repository = self._owner .. "/" .. self._repo,
    account = vim.fn.sha256(vim.json.encode({ token, login })),
  }
end
return M
