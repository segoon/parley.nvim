local identity = require("parley.cache_identity")
local keys = require("parley.repositories.review_keys")

describe("provider cache identities", function()
  --- @param overrides? table
  --- @return table
  local function snapshot(overrides)
    local value = vim.tbl_extend(
      "force",
      { provider = "custom", host = "host", repository = "repo", account = "fingerprint" },
      overrides or {}
    )
    return identity.snapshot({
      cache_identity = function()
        return value
      end,
    }, {})
  end
  it("shares stable identities and separates each identity dimension", function()
    local base = snapshot()
    assert.equals(base.scope, snapshot().scope)
    for _, field in ipairs({ "provider", "host", "repository", "account" }) do
      assert.is_not.equals(base.scope, snapshot({ [field] = "different" }).scope)
    end
    assert.is_nil(base.opts.repository)
    assert.equals("reviews-v2", keys.pr(base, "a/b").provider)
    assert.is_not.equals(keys.pr(base, "a/b").subkey, keys.pr(base, "a_b").subkey)
    assert.is_not.equals(keys.pr(base, "42").subkey, keys.discussions(base, "42").subkey)
  end)
  it("isolates unavailable identity and disables persistent keys", function()
    local p = {
      cache_identity = function()
        return nil
      end,
    }
    local first, second = identity.snapshot(p, {}), identity.snapshot(p, {})
    assert.is_false(first.persistent)
    assert.is_not.equals(first.scope, second.scope)
    assert.is_nil(keys.pr(first, "branch"))
    assert.is_nil(keys.discussions(first, "1"))
  end)
  it("rejects missing methods and malformed identities", function()
    assert.has_error(function()
      identity.snapshot({}, {})
    end)
    assert.has_error(function()
      snapshot({ account = "" })
    end)
  end)
  it("detects changed credentials without putting raw identity in keys", function()
    local account = "first"
    local s = identity.snapshot({
      cache_identity = function()
        return { provider = "custom", host = "host", repository = "repo", account = account }
      end,
    }, {})
    assert.is_true(identity.matches(s))
    account = "second"
    assert.is_false(identity.matches(s))
    assert.is_nil(vim.inspect(keys.pr(s, "branch")):find("first", 1, true))
  end)
end)
