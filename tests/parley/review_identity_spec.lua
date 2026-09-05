local a = require("plenary.async.tests")
local review = require("parley.repositories.review")
local contexts = require("parley.repositories.context")
local providers = require("parley.repositories.provider")
local registry = require("parley.registry")
local cache = require("parley.cache")
local mock = require("parley.mock_provider")
local identities = require("parley.cache_identity")
local keys = require("parley.repositories.review_keys")

a.describe("review identity lifecycle", function()
  local saved, ctx, provider, disk, writes, reads
  a.before_each(function()
    saved = {
      context_get = contexts.get,
      context_refresh = contexts.refresh,
      specs = registry.registered(),
      fs = cache._fs,
      config = review._get_config,
      entries = providers._entries,
      refresh = review.refresh_async,
    }
    for _, name in ipairs({
      "_reviews",
      "_views",
      "_bufnr_key",
      "_key_bufnrs",
      "_in_flight",
      "_pending_force",
      "_subscribers",
    }) do
      saved[name] = review[name]
      review[name] = {}
    end
    disk, writes, reads = {}, 0, 0
    cache._fs = {
      read = function(path)
        reads = reads + 1
        return disk[path]
      end,
      write = function(path, text)
        writes = writes + 1
        disk[path] = text
      end,
      delete = function(path)
        disk[path] = nil
      end,
      mkdir = function() end,
    }
    cache.setup({ cache_dir = "/tmp/parley-identity-memory" })
    providers._entries = {}
    ctx = { kind = "regular", rel_path = "f", vcs_info = { vcs = "custom", root = "/checkout", branch = "branch" } }
    contexts.get, contexts.refresh = function()
      return ctx
    end, function()
      return ctx
    end
    provider = mock.new({ pr = { id = "1" }, head_sha = "rev", discussions = {} })
    registry.reset()
    registry.register({
      name = "Custom",
      detect = function()
        return { arbitrary = "opts" }
      end,
      factory = function()
        return provider
      end,
    })
    review._get_config = function()
      return {}
    end
  end)
  a.after_each(function()
    contexts.get, contexts.refresh = saved.context_get, saved.context_refresh
    registry.reset()
    for _, spec in ipairs(saved.specs) do
      registry.register(spec)
    end
    cache._fs, review._get_config, providers._entries = saved.fs, saved.config, saved.entries
    review.refresh_async = saved.refresh
    for _, name in ipairs({
      "_reviews",
      "_views",
      "_bufnr_key",
      "_key_bufnrs",
      "_in_flight",
      "_pending_force",
      "_subscribers",
    }) do
      review[name] = saved[name]
    end
  end)

  a.it("keeps live reviews available with no persistent identity and no disk calls", function()
    provider.cache_identity = function()
      return nil
    end
    local result = review.refresh(1)
    assert.equals("1", result.pr.id)
    review.invalidate(1)
    assert.equals(0, reads)
    assert.equals(0, writes)
  end)

  a.it("ignores legacy cache records and invalidates only new keys", function()
    local legacy = { provider = "github", repository = "owner/repo", subkey = "pr_branch_branch" }
    cache.set(legacy, { legacy = true })
    review.refresh(1)
    assert.equals(1, #provider.calls.detect_pr)
    local snapshot = providers.get(1)
    assert.is_not_nil(cache.get(keys.pr(snapshot, "branch")))
    review.invalidate(1)
    assert.is_nil(cache.get(keys.pr(snapshot, "branch")))
    assert.is_not_nil(cache.get(legacy))
  end)

  a.it("discards changed-credential fetch results before any cache write", function()
    local account = "old"
    provider.cache_identity = function()
      return { provider = "custom", host = "host", repository = "repo", account = account }
    end
    local old = identities.snapshot(provider, {})
    provider.fetch_discussions = function()
      account = "new"
      return {}
    end
    local retried = false
    review.refresh_async = function()
      retried = true
    end
    assert.is_nil(review.refresh(1))
    assert.equals(0, writes)
    assert.is_nil(review._reviews[keys.make(old, ctx)])
    assert.is_true(vim.wait(100, function()
      return retried
    end))
  end)

  a.it("does not publish after identity changes during local projection", function()
    local mappings = require("parley.repositories.local_mappings")
    local old_get, account, published = mappings.get, "old", false
    provider.cache_identity = function()
      return { provider = "custom", host = "host", repository = "repo", account = account }
    end
    mappings.get = function()
      account = "new"
      return {}
    end
    local unsubscribe = review.subscribe(1, function(value)
      if value then
        published = true
      end
    end)
    local retried = false
    review.refresh_async = function()
      retried = true
    end
    local result = review.refresh(1)
    mappings.get = old_get
    unsubscribe()
    assert.is_nil(result)
    assert.is_false(published)
    assert.is_nil(review.get(1))
    assert.is_true(vim.wait(100, function()
      return retried
    end))
  end)

  a.it("uses validated construction for the actual repository path", function()
    provider.cache_identity = nil
    assert.has_error(function()
      providers.refresh(1)
    end)
  end)
end)
