local a = require("plenary.async.tests")
local github = require("parley.providers.github.provider")

a.describe("prepared GitHub cache identity", function()
  a.it("fingerprints CLI credentials and keeps cache getters free of I/O", function()
    local token, calls = "SECRET", 0
    local p = github.new({
      repository = "o/r",
      host = "host",
      _auth = {
        read_token_async = function()
          calls = calls + 1
          return token
        end,
      },
    })
    assert.is_nil(p:cache_identity())
    p:prepare()
    local first = p:cache_identity()
    assert.is_nil(vim.inspect(first):find(token, 1, true))
    assert.same(first, p:cache_identity())
    assert.equals(1, calls)
    token = "OTHER"
    p:prepare()
    assert.is_not.equals(first.account, p:cache_identity().account)
    p._host = "another-host"
    assert.is_nil(p:cache_identity())
  end)
  a.it("disables persistent caching when CLI credentials cannot be established", function()
    local p = github.new({
      repository = "o/r",
      _auth = {
        read_token_async = function()
          return nil
        end,
      },
    })
    p:prepare()
    assert.is_nil(p:cache_identity())
  end)
end)
