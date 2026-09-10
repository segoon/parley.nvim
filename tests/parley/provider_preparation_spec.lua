local providers = require("parley.repositories.provider")
local contexts = require("parley.repositories.context")
local registry = require("parley.registry")
local reviews = require("parley.repositories.review")
local cache = require("parley.cache")
describe("provider preparation before cache publication", function()
  local saved, buf, p, prepared, reads, info
  before_each(function()
    saved = { registry.resolve_with_opts, contexts.refresh, cache.get_async }
    buf = vim.api.nvim_create_buf(false, true)
    info = { vcs = "arc", root = "/repo", branch = "feature" }
    contexts._entries[buf] = { kind = "regular", rel_path = "f", vcs_info = info }
    contexts.refresh = function()
      return contexts.get(buf)
    end
    prepared, reads = false, 0
    p = {
      prepare = function(_, actual)
        assert.same(info, actual)
        prepared = true
      end,
      cache_identity = function()
        assert.is_true(prepared)
        return { provider = "test", host = "host", repository = "repo", account = "verified" }
      end,
    }
    registry.resolve_with_opts = function()
      return p, {}
    end
    cache.get_async = function()
      reads = reads + 1
    end
  end)
  after_each(function()
    registry.resolve_with_opts, contexts.refresh, cache.get_async = saved[1], saved[2], saved[3]
    providers.invalidate(buf)
    reviews.detach(buf)
    contexts._entries[buf] = nil
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
  it("prepares before computing or publishing identity", function()
    local snapshot = providers.refresh(buf)
    assert.equals("verified", snapshot.identity.account)
    assert.is_true(prepared)
  end)
  it("does not publish a provider prepared for an obsolete checkout context", function()
    p.prepare = function()
      prepared = true
      contexts._entries[buf].vcs_info.branch = "other"
    end
    assert.has_error(function()
      providers.refresh(buf)
    end)
    assert.is_nil(providers.get(buf))
  end)
  it("clears obsolete provider and review data without restoring disk cache on failure", function()
    providers.refresh(buf)
    reviews._seed(buf, { all_discussions = { { id = "old", resolved = false } } })
    p.prepare = function()
      error("verification failed")
    end
    assert.has_error(function()
      reviews.refresh(buf)
    end)
    assert.is_nil(providers.get(buf))
    assert.is_nil(reviews.get(buf))
    assert.equals(0, reads)
  end)
end)
