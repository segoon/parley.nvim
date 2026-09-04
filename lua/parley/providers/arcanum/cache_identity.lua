--- Arcanum owns credential and Arc-login scope; no server lookup is needed.
local M = {}
--- @param self parley.arcanum.Provider
--- @return parley.CacheIdentity|nil
function M.get(self)
  local reader = self._auth.read_token_async or self._auth.read_token
  local ok, token = pcall(reader)
  if not ok or not token or token == "" then
    return nil
  end
  return {
    provider = "arcanum",
    host = self._host,
    repository = "arcanum",
    account = vim.fn.sha256(vim.json.encode({ token, self._viewer_login or "" })),
  }
end
return M
