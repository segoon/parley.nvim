--- Tests for parley.cache — disk cache module.
--- Run via: make test

local cache = require("parley.cache")

-- ---------------------------------------------------------------------------
-- Fake filesystem helpers
-- ---------------------------------------------------------------------------

--- Build a fake in-memory filesystem seam.
---
--- Models a flat key-value store keyed by absolute path.  delete removes
--- the exact path and all children (simulating `rm -rf`).
---
--- @return table fs, table store, table deleted_paths
local function make_fake_fs()
  local store = {} -- path -> string content
  local deleted_paths = {}

  local fs = {}

  function fs.read(path)
    return store[path]
  end

  function fs.write(path, content)
    store[path] = content
  end

  function fs.delete(path)
    table.insert(deleted_paths, path)
    local prefix = path .. "/"
    local to_remove = {}
    for k in pairs(store) do
      if k == path or k:sub(1, #prefix) == prefix then
        table.insert(to_remove, k)
      end
    end
    for _, k in ipairs(to_remove) do
      store[k] = nil
    end
  end

  function fs.mkdir(_path)
    -- no-op: directories are implicit in the fake store
  end

  return fs, store, deleted_paths
end

--- Inject a fresh fake fs and call cache.setup().
--- Returns the fake fs, raw store, and deleted_paths list for inspection.
---
--- @param cache_dir? string  defaults to "/fake/cache/parley"
--- @return table fs, table store, table deleted_paths
local function setup_cache(cache_dir)
  cache_dir = cache_dir or "/fake/cache/parley"
  local fs, store, deleted_paths = make_fake_fs()
  cache._fs = fs
  cache.setup({ cache_dir = cache_dir })
  return fs, store, deleted_paths
end

local function teardown_cache()
  cache._fs = nil
end

-- Convenience key factories.
local function key(provider, repository, subkey)
  return { provider = provider, repository = repository, subkey = subkey }
end

-- ---------------------------------------------------------------------------
-- cache.setup
-- ---------------------------------------------------------------------------

describe("parley.cache.setup", function()
  after_each(teardown_cache)

  it("raises when cache_dir is absent", function()
    cache._fs = make_fake_fs()
    assert.has_error(function()
      cache.setup({})
    end)
  end)

  it("raises when cache_dir is not a string", function()
    cache._fs = make_fake_fs()
    assert.has_error(function()
      cache.setup({ cache_dir = 42 })
    end)
  end)

  it("raises when cache_dir is an empty string", function()
    cache._fs = make_fake_fs()
    assert.has_error(function()
      cache.setup({ cache_dir = "" })
    end)
  end)

  it("accepts a valid cache_dir without error", function()
    setup_cache("/tmp/parley_test")
    -- no assertion needed — absence of error is the contract
  end)
end)

-- ---------------------------------------------------------------------------
-- cache.get — key validation
-- ---------------------------------------------------------------------------

describe("parley.cache.get — key validation", function()
  before_each(function()
    setup_cache()
  end)
  after_each(teardown_cache)

  it("raises when key is nil", function()
    assert.has_error(function()
      cache.get(nil)
    end)
  end)

  it("raises when provider field is missing", function()
    assert.has_error(function()
      cache.get({ repository = "r", subkey = "s" })
    end)
  end)

  it("raises when repository field is missing", function()
    assert.has_error(function()
      cache.get({ provider = "p", subkey = "s" })
    end)
  end)

  it("raises when subkey field is missing", function()
    assert.has_error(function()
      cache.get({ provider = "p", repository = "r" })
    end)
  end)

  it("raises when a field is not a string", function()
    assert.has_error(function()
      cache.get({ provider = "github", repository = 99, subkey = "s" })
    end)
  end)

  it("raises when a field is an empty string", function()
    assert.has_error(function()
      cache.get({ provider = "", repository = "r", subkey = "s" })
    end)
  end)
end)

-- ---------------------------------------------------------------------------
-- cache.get — cache misses
-- ---------------------------------------------------------------------------

describe("parley.cache.get — misses", function()
  before_each(function()
    setup_cache()
  end)
  after_each(teardown_cache)

  it("returns nil for a key that was never set", function()
    assert.is_nil(cache.get(key("github", "owner/repo", "comments")))
  end)

  it("returns nil when the stored file contains invalid JSON", function()
    cache._fs.write("/fake/cache/parley/github/owner_repo/comments.json", "NOT JSON {{")
    assert.is_nil(cache.get(key("github", "owner/repo", "comments")))
  end)

  it("returns nil when the entry is missing the data field", function()
    cache._fs.write("/fake/cache/parley/github/owner_repo/ep.json", '{"fetched_at":1}')
    assert.is_nil(cache.get(key("github", "owner/repo", "ep")))
  end)

  it("returns nil when the entry is missing fetched_at", function()
    cache._fs.write("/fake/cache/parley/github/owner_repo/ep.json", '{"data":"x"}')
    assert.is_nil(cache.get(key("github", "owner/repo", "ep")))
  end)
end)

-- ---------------------------------------------------------------------------
-- cache.set / cache.get — round-trip
-- ---------------------------------------------------------------------------

describe("parley.cache.set + cache.get round-trip", function()
  local store

  before_each(function()
    local _, s = setup_cache()
    store = s
  end)
  after_each(teardown_cache)

  it("stores and retrieves a string value", function()
    cache.set(key("github", "owner/repo", "comments"), "hello")
    local entry = cache.get(key("github", "owner/repo", "comments"))
    assert.is_not_nil(entry)
    assert.equals("hello", entry.data)
  end)

  it("stores and retrieves a table value", function()
    local data = { threads = { { id = 1 }, { id = 2 } } }
    cache.set(key("github", "owner/repo", "threads"), data)
    local entry = cache.get(key("github", "owner/repo", "threads"))
    assert.is_not_nil(entry)
    assert.same(data, entry.data)
  end)

  it("stores and retrieves a number value", function()
    cache.set(key("github", "owner/repo", "count"), 42)
    local entry = cache.get(key("github", "owner/repo", "count"))
    assert.is_not_nil(entry)
    assert.equals(42, entry.data)
  end)

  it("stores and retrieves a boolean false value", function()
    cache.set(key("github", "owner/repo", "flag"), false)
    local entry = cache.get(key("github", "owner/repo", "flag"))
    assert.is_not_nil(entry)
    assert.is_false(entry.data)
  end)

  it("entry includes a fetched_at timestamp close to now", function()
    local before = os.time()
    cache.set(key("github", "owner/repo", "ts_test"), "x")
    local after = os.time()
    local entry = cache.get(key("github", "owner/repo", "ts_test"))
    assert.is_not_nil(entry)
    assert.is_true(entry.fetched_at >= before)
    assert.is_true(entry.fetched_at <= after)
  end)

  it("writes a .json file at the sanitized path", function()
    cache.set(key("github", "owner/repo", "my_endpoint"), { ok = true })
    assert.is_not_nil(store["/fake/cache/parley/github/owner_repo/my_endpoint.json"])
  end)

  it("overwriting a key updates data and fetched_at", function()
    cache.set(key("github", "owner/repo", "ep"), "first")
    local e1 = cache.get(key("github", "owner/repo", "ep"))
    cache.set(key("github", "owner/repo", "ep"), "second")
    local e2 = cache.get(key("github", "owner/repo", "ep"))
    assert.equals("second", e2.data)
    assert.is_true(e2.fetched_at >= e1.fetched_at)
  end)
end)

-- ---------------------------------------------------------------------------
-- Sanitization
-- ---------------------------------------------------------------------------

describe("parley.cache — key sanitization", function()
  local store

  before_each(function()
    local _, s = setup_cache()
    store = s
  end)
  after_each(teardown_cache)

  it("sanitizes slash in repository to underscore", function()
    cache.set(key("github", "owner/repo", "comments"), "data")
    assert.is_not_nil(store["/fake/cache/parley/github/owner_repo/comments.json"])
  end)

  it("sanitizes spaces in any field to underscore", function()
    cache.set(key("my provider", "some repo", "my endpoint"), "data")
    local entry = cache.get(key("my provider", "some repo", "my endpoint"))
    assert.is_not_nil(entry)
    assert.equals("data", entry.data)
    -- Confirm a path with underscores was written
    local found = false
    for path in pairs(store) do
      if path:find("my_provider") and path:find("some_repo") and path:find("my_endpoint") then
        found = true
      end
    end
    assert.is_true(found)
  end)

  it("preserves alphanumeric, dash, underscore, dot", function()
    cache.set(key("github", "owner-repo.org_1", "v2.comments"), "ok")
    local entry = cache.get(key("github", "owner-repo.org_1", "v2.comments"))
    assert.is_not_nil(entry)
    assert.equals("ok", entry.data)
  end)
end)

-- ---------------------------------------------------------------------------
-- cache.invalidate
-- ---------------------------------------------------------------------------

describe("parley.cache.invalidate", function()
  before_each(function()
    setup_cache()
  end)
  after_each(teardown_cache)

  it("removes a previously set key", function()
    cache.set(key("github", "owner/repo", "comments"), "x")
    cache.invalidate(key("github", "owner/repo", "comments"))
    assert.is_nil(cache.get(key("github", "owner/repo", "comments")))
  end)

  it("does not error when the key does not exist", function()
    assert.has_no_error(function()
      cache.invalidate(key("github", "owner/repo", "nonexistent"))
    end)
  end)

  it("only removes the targeted key, not siblings", function()
    cache.set(key("github", "owner/repo", "comments"), "a")
    cache.set(key("github", "owner/repo", "threads"), "b")
    cache.invalidate(key("github", "owner/repo", "comments"))
    assert.is_nil(cache.get(key("github", "owner/repo", "comments")))
    assert.is_not_nil(cache.get(key("github", "owner/repo", "threads")))
  end)
end)

-- ---------------------------------------------------------------------------
-- cache.invalidate_prefix
-- ---------------------------------------------------------------------------

describe("parley.cache.invalidate_prefix — provider only", function()
  local deleted_paths

  before_each(function()
    local _, _, dp = setup_cache()
    deleted_paths = dp
  end)
  after_each(teardown_cache)

  it("removes all entries for the given provider", function()
    cache.set(key("github", "owner/repo", "comments"), "a")
    cache.set(key("github", "owner/repo", "threads"), "b")
    cache.set(key("gitlab", "owner/repo", "comments"), "c")

    cache.invalidate_prefix({ provider = "github" })

    assert.is_nil(cache.get(key("github", "owner/repo", "comments")))
    assert.is_nil(cache.get(key("github", "owner/repo", "threads")))
    -- gitlab entry must survive
    assert.is_not_nil(cache.get(key("gitlab", "owner/repo", "comments")))
  end)

  it("calls fs.delete on the provider directory", function()
    cache.invalidate_prefix({ provider = "github" })
    local found = false
    for _, p in ipairs(deleted_paths) do
      if p == "/fake/cache/parley/github" then
        found = true
      end
    end
    assert.is_true(found)
  end)

  it("does not error when provider directory does not exist", function()
    assert.has_no_error(function()
      cache.invalidate_prefix({ provider = "github" })
    end)
  end)

  it("raises when provider is missing", function()
    assert.has_error(function()
      cache.invalidate_prefix({})
    end)
  end)
end)

describe("parley.cache.invalidate_prefix — provider + repository", function()
  local deleted_paths

  before_each(function()
    local _, _, dp = setup_cache()
    deleted_paths = dp
  end)
  after_each(teardown_cache)

  it("removes all entries for that repo, leaves other repos intact", function()
    cache.set(key("github", "owner/repo-a", "comments"), "a")
    cache.set(key("github", "owner/repo-a", "threads"), "b")
    cache.set(key("github", "owner/repo-b", "comments"), "c")

    cache.invalidate_prefix({ provider = "github", repository = "owner/repo-a" })

    assert.is_nil(cache.get(key("github", "owner/repo-a", "comments")))
    assert.is_nil(cache.get(key("github", "owner/repo-a", "threads")))
    assert.is_not_nil(cache.get(key("github", "owner/repo-b", "comments")))
  end)

  it("calls fs.delete on the sanitized repository directory", function()
    cache.invalidate_prefix({ provider = "github", repository = "owner/repo-a" })
    local found = false
    for _, p in ipairs(deleted_paths) do
      if p == "/fake/cache/parley/github/owner_repo-a" then
        found = true
      end
    end
    assert.is_true(found)
  end)

  it("does not error when repository directory does not exist", function()
    assert.has_no_error(function()
      cache.invalidate_prefix({ provider = "github", repository = "owner/repo-z" })
    end)
  end)
end)

-- ---------------------------------------------------------------------------
-- cache.is_stale
-- ---------------------------------------------------------------------------

describe("parley.cache.is_stale", function()
  after_each(teardown_cache)

  it("returns false when fetched_at is recent", function()
    local entry = { data = "x", fetched_at = os.time() }
    assert.is_false(cache.is_stale(entry, 300))
  end)

  it("returns true when fetched_at is older than ttl", function()
    local entry = { data = "x", fetched_at = os.time() - 400 }
    assert.is_true(cache.is_stale(entry, 300))
  end)

  it("returns true when elapsed time equals ttl exactly", function()
    local entry = { data = "x", fetched_at = os.time() - 300 }
    assert.is_true(cache.is_stale(entry, 300))
  end)

  it("raises when entry is nil", function()
    assert.has_error(function()
      cache.is_stale(nil, 300)
    end)
  end)

  it("raises when ttl is not a number", function()
    local entry = { data = "x", fetched_at = os.time() }
    assert.has_error(function()
      cache.is_stale(entry, "300")
    end)
  end)

  it("raises when fetched_at is missing from entry", function()
    assert.has_error(function()
      cache.is_stale({ data = "x" }, 300)
    end)
  end)
end)
