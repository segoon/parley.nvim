--- Bind authenticated ownership, HTTP credentials, and cache identity to one verified session.
local transport = require("parley.providers.arcanum.transport")
local M = {}
--- @param self parley.arcanum.Provider
--- @return string|nil, string|nil
local function credential(self)
  local ok, token, err = pcall(self._auth.read_token)
  if not ok then
    return nil, "Arcanum credential resolution failed"
  end
  if type(token) ~= "string" or not token:find("%S") then
    return nil, err or "No Arcanum credential available"
  end
  return token
end
--- @param self parley.arcanum.Provider
--- @return boolean
function M.current(self)
  local token = credential(self)
  return self._verified_host == self._host
    and token ~= nil
    and token == self._token
    and token == self._verified_token
    and type(self._viewer_login) == "string"
    and self._viewer_login ~= ""
end
--- @param self parley.arcanum.Provider
function M.require_verified(self)
  if not M.current(self) then
    error("Arcanum account is unverified or credentials changed; refresh the review before continuing", 0)
  end
end
--- @param self parley.arcanum.Provider
--- @param info? parley.VcsInfo Preparation is unnecessary without a remote branch.
function M.prepare(self, info)
  if info and (type(info.branch) ~= "string" or info.branch == "") then
    return
  end
  if M.current(self) then
    return
  end
  self._viewer_login, self._verified_token = nil, nil
  local host = self._host
  local token, err = credential(self)
  if not token then
    error(err, 0)
  end
  self._token = token
  local ok, result = pcall(transport.http_run, self, "GET", "/v2/users/me?fields=name")
  if not ok then
    error("Arcanum account verification failed; check credentials, host, and connectivity", 0)
  end
  if type(result) ~= "table" or type(result.name) ~= "string" or not result.name:find("%S") then
    error("Arcanum account verification returned no valid user name", 0)
  end
  if credential(self) ~= token or self._host ~= host then
    error("Arcanum credentials changed during verification; refresh the review", 0)
  end
  self._viewer_login, self._verified_token, self._verified_host = result.name, token, host
end
return M
