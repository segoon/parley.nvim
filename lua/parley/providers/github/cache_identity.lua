--- Prepared GitHub credential identity; synchronous getters never perform I/O.
local M = {}

--- @param self parley.github.Provider
--- @return string|nil
local function credential(self)
  local read = self._auth.read_token_async or self._auth.read_token
  local ok, token = pcall(read, self._host, { timeout_ms = self._config.timeout_ms, system = self._system })
  return ok and type(token) == "string" and token:find("%S") and token or nil
end

--- @param self parley.github.Provider
--- @return string
local function context(self)
  return vim.json.encode({ self._host, self._api_base, self._owner, self._repo })
end

--- Resolve a new session before publishing its cache identity; yields.
--- @param self parley.github.Provider
function M.prepare(self)
  self._session_generation = (self._session_generation or 0) + 1
  local generation = self._session_generation
  self._prepared, self._session_valid = true, false
  self._viewer_login = nil
  self._thread_node_ids = {}
  local scope = context(self)
  local token = credential(self)
  if self._session_generation ~= generation then
    return
  end
  self._session_token, self._session_context = token, scope
  self._prepared, self._session_valid = true, scope == context(self)
end

--- Revalidate around asynchronous API operations, invalidating obsolete results.
--- @param self parley.github.Provider
--- @return boolean
function M.check(self)
  if not self._prepared then
    return true
  end
  local generation = self._session_generation
  local scope, token = self._session_context, self._session_token
  local current = credential(self)
  if self._session_generation ~= generation then
    return false
  end
  local valid = self._session_valid
    and scope == context(self)
    and current == token
    and self._session_context == scope
    and self._session_token == token
  if not valid then
    self._session_valid, self._viewer_login = false, nil
    self._thread_node_ids = {}
  end
  return valid == true
end

--- @param self parley.github.Provider
--- @return parley.CacheIdentity|nil
function M.get(self)
  if not self._session_valid or not self._session_token or self._session_context ~= context(self) then
    return nil
  end
  return {
    provider = "github",
    host = self._host .. "\0" .. self._api_base,
    repository = self._owner .. "/" .. self._repo,
    account = vim.fn.sha256(self._session_token),
  }
end
return M
