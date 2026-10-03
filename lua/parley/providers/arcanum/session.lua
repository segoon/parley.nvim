--- Bind Arc ownership, selected credentials, and cache identity to one local session.
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
  return self._session_host == self._host
    and token ~= nil
    and token == self._token
    and token == self._session_token
    and type(self._viewer_login) == "string"
    and self._viewer_login:find("%S") ~= nil
    and self._viewer_login == self._arc_login
end
--- @param self parley.arcanum.Provider
function M.require_current(self)
  if not M.current(self) then
    error("Arcanum session is unavailable or credentials changed; refresh the review before continuing", 0)
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
  self._viewer_login, self._session_token = nil, nil
  local host = self._host
  local token, err = credential(self)
  if not token then
    error(err, 0)
  end
  self._token = token
  local login = self._arc_login
  if type(login) ~= "string" or not login:find("%S") then
    error("Arc user login is unavailable; check arc info and refresh the review", 0)
  end
  self._viewer_login, self._session_token, self._session_host = login, token, host
end
return M
