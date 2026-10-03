--- Cache identity uses the Arc login bound to the current credential.
local M = {}
--- @param self parley.arcanum.Provider
--- @return parley.CacheIdentity|nil
function M.get(self)
  if not require("parley.providers.arcanum.session").current(self) then
    return nil
  end
  return {
    provider = "arcanum",
    host = self._host,
    repository = "arcanum",
    account = vim.fn.sha256(vim.json.encode({ "arc-viewer-review-v5", self._token, self._viewer_login })),
  }
end
return M
