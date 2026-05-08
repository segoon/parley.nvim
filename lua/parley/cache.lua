--- parley.cache — Disk cache for API responses.
---
--- Caches arbitrary Lua values (anything that round-trips through
--- vim.json.encode / vim.json.decode) keyed by a structured parley.CacheKey.
---
--- Storage layout:
---   {cache_dir}/{provider}/{repository}/{subkey}.json
---
--- Each component is sanitized: only [a-zA-Z0-9._-] is kept; all other
--- characters (including '/') are replaced with '_'.
---
--- Each cache file contains JSON:
---   { "data": <value>, "fetched_at": <unix timestamp> }
---
--- Testability:
---   Set M._fs to a fake backend before calling any function; restore to nil
---   in after_each.  The fake must implement: read(path), write(path, content),
---   delete(path), mkdir(path).

local M = {}

-- ---------------------------------------------------------------------------
-- Type annotations
-- ---------------------------------------------------------------------------

--- Structured cache key.  All three fields are required non-empty strings.
--- The repository field may contain raw characters such as '/' — the cache
--- module sanitizes them internally.
---
--- @class parley.CacheKey
--- @field provider   string  Provider identifier, e.g. "github"
--- @field repository string  Repository identifier, e.g. "owner/repo"
--- @field subkey     string  Endpoint / data name, e.g. "review_comments"

--- A cache entry as returned by cache.get().
---
--- @class parley.CacheEntry
--- @field data       any      The cached value
--- @field fetched_at integer  Unix timestamp (os.time()) when the entry was stored

-- ---------------------------------------------------------------------------
-- Injectable filesystem backend (for testing)
-- ---------------------------------------------------------------------------

--- Override the filesystem backend in tests.  nil = use the real filesystem.
--- Must implement: read(path), write(path, content), delete(path), mkdir(path).
--- @type table|nil
M._fs = nil

--- Return the active filesystem backend.
--- @return table
local function fs()
  if M._fs then
    return M._fs
  end
  return {
    read = function(path)
      local fh = io.open(path, "r")
      if not fh then
        return nil
      end
      local content = fh:read("*a")
      fh:close()
      return content
    end,
    write = function(path, content)
      -- Ensure parent directory exists.
      local parent = path:match("^(.*)/[^/]+$")
      if parent then
        vim.fn.mkdir(parent, "p")
      end
      local fh = assert(io.open(path, "w"))
      fh:write(content)
      fh:close()
    end,
    delete = function(path)
      vim.fn.delete(path, "rf")
    end,
    mkdir = function(path)
      vim.fn.mkdir(path, "p")
    end,
  }
end

-- ---------------------------------------------------------------------------
-- Module state
-- ---------------------------------------------------------------------------

--- Active cache directory.  Set by setup().
--- @type string|nil
local cache_dir = nil

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Sanitize a single path component: keep [a-zA-Z0-9._-], replace others
--- with '_'.
---
--- @param component string
--- @return string
local function sanitize(component)
  return component:gsub("[^a-zA-Z0-9._%-]", "_")
end

--- Convert a parley.CacheKey to an absolute file path.
---
--- @param key parley.CacheKey
--- @return string
local function key_to_path(key)
  return cache_dir
    .. "/"
    .. sanitize(key.provider)
    .. "/"
    .. sanitize(key.repository)
    .. "/"
    .. sanitize(key.subkey)
    .. ".json"
end

--- Validate that a parley.CacheKey is well-formed.  Raises on failure.
---
--- @param key any
local function validate_key(key)
  assert(type(key) == "table", "parley.cache: key must be a table")
  for _, field in ipairs({ "provider", "repository", "subkey" }) do
    assert(
      type(key[field]) == "string" and key[field] ~= "",
      "parley.cache: key." .. field .. " must be a non-empty string"
    )
  end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Set up the cache module.
---
--- Must be called before any other function.  Typically called from
--- parley.setup() with the value of config.cache_dir.
---
--- @param cfg { cache_dir: string }
function M.setup(cfg)
  assert(type(cfg) == "table", "parley.cache.setup: cfg must be a table")
  assert(
    type(cfg.cache_dir) == "string" and cfg.cache_dir ~= "",
    "parley.cache.setup: cfg.cache_dir must be a non-empty string"
  )
  cache_dir = cfg.cache_dir
  fs().mkdir(cache_dir)
end

--- Retrieve a cached entry.
---
--- Returns nil on a cache miss, unreadable file, malformed JSON, or a stored
--- entry that is missing required fields.  Never raises for I/O issues.
---
--- Must be called after setup().
---
--- @param key parley.CacheKey
--- @return parley.CacheEntry|nil
function M.get(key)
  validate_key(key)
  local path = key_to_path(key)
  local raw = fs().read(path)
  if raw == nil then
    return nil
  end
  local ok, entry = pcall(vim.json.decode, raw)
  if not ok or type(entry) ~= "table" then
    return nil
  end
  -- Both fields must be present; data may be any JSON-decoded type but
  -- fetched_at must be a number.  A missing "data" key (or JSON null decoded
  -- to nil) is treated as a cache miss.
  if entry.data == nil then
    return nil
  end
  if type(entry.fetched_at) ~= "number" then
    return nil
  end
  return { data = entry.data, fetched_at = entry.fetched_at }
end

--- Store a value in the cache under the given key.
---
--- Overwrites any existing entry.  The fetched_at timestamp is set to the
--- current time (os.time()).
---
--- Must be called after setup().
---
--- @param key  parley.CacheKey
--- @param data any  Value to cache (must be JSON-encodable)
function M.set(key, data)
  validate_key(key)
  local path = key_to_path(key)
  -- Ensure parent directory exists.
  local parent = path:match("^(.*)/[^/]+$")
  if parent then
    fs().mkdir(parent)
  end
  local entry = { data = data, fetched_at = os.time() }
  fs().write(path, vim.json.encode(entry))
end

--- Delete the cache entry for a single key.
---
--- No-op when the entry does not exist.
---
--- @param key parley.CacheKey
function M.invalidate(key)
  validate_key(key)
  local path = key_to_path(key)
  fs().delete(path)
end

--- Delete all cache entries under a provider (and optionally a repository).
---
--- Accepted shapes:
---   { provider = "github" }                        — removes cache_dir/github/
---   { provider = "github", repository = "o/r" }   — removes cache_dir/github/o_r/
---
--- No-op when the target directory does not exist.  Raises when provider is
--- missing or not a string.
---
--- @param partial_key { provider: string, repository?: string }
function M.invalidate_prefix(partial_key)
  assert(
    type(partial_key) == "table" and type(partial_key.provider) == "string" and partial_key.provider ~= "",
    "parley.cache.invalidate_prefix: partial_key.provider must be a non-empty string"
  )
  local path = cache_dir .. "/" .. sanitize(partial_key.provider)
  if type(partial_key.repository) == "string" and partial_key.repository ~= "" then
    path = path .. "/" .. sanitize(partial_key.repository)
  end
  fs().delete(path)
end

--- Return true when a cache entry is considered stale.
---
--- An entry is stale when `os.time() - entry.fetched_at >= ttl`.
---
--- @param entry parley.CacheEntry
--- @param ttl   integer  Time-to-live in seconds
--- @return boolean
function M.is_stale(entry, ttl)
  assert(type(entry) == "table", "parley.cache.is_stale: entry must be a table")
  assert(type(entry.fetched_at) == "number", "parley.cache.is_stale: entry.fetched_at must be a number")
  assert(type(ttl) == "number", "parley.cache.is_stale: ttl must be a number")
  return os.time() - entry.fetched_at >= ttl
end

return M
