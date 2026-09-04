--- Validate public cache identities without interpreting provider-specific data.
--- @class parley.ProviderSnapshot
--- @field status 'ready'
--- @field provider parley.Provider
--- @field opts table Opaque provider construction options
--- @field identity? parley.CacheIdentity
--- @field persistent boolean
--- @field scope string Hashed identity or unique temporary scope

local M = {}
local sequence = 0

--- @param values table
--- @return string
function M.digest(values)
  return vim.fn.sha256(vim.json.encode(values))
end

--- @param provider parley.Provider
--- @return table|nil
local function read(provider)
  assert(type(provider.cache_identity) == "function", "Provider must implement cache_identity")
  local ok, value = pcall(provider.cache_identity, provider)
  assert(ok, "Provider cache identity resolution failed")
  if value == nil then
    return nil
  end
  assert(type(value) == "table", "Provider cache identity must be a table")
  local result = {}
  for _, field in ipairs({ "provider", "host", "repository", "account" }) do
    assert(type(value[field]) == "string" and value[field] ~= "", "Invalid cache identity field: " .. field)
    result[field] = value[field]
  end
  return result
end

--- @param value table
--- @return string
local function scope(value)
  return M.digest({ value.provider, value.host, value.repository, value.account })
end

--- @param provider parley.Provider
--- @param opts table
--- @return parley.ProviderSnapshot
function M.snapshot(provider, opts)
  local value = read(provider)
  sequence = sequence + 1
  return {
    status = "ready",
    provider = provider,
    opts = vim.deepcopy(opts),
    identity = value,
    persistent = value ~= nil,
    scope = value and scope(value) or ("temporary-" .. sequence),
  }
end

--- Revalidate after asynchronous work; nil identities stay local to this snapshot.
--- @param snapshot parley.ProviderSnapshot
--- @return boolean
function M.matches(snapshot)
  local value = read(snapshot.provider)
  return snapshot.persistent and value ~= nil and scope(value) == snapshot.scope
    or not snapshot.persistent and value == nil
end
return M
