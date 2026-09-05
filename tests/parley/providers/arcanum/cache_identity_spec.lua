local identity = require("parley.providers.arcanum.cache_identity")
describe("Arcanum cache identity", function()
  it("isolates host, login, and token without returning the token", function()
    local token = "SECRET"
    local p = {
      _host = "host",
      _verified_host = "host",
      _verified_token = token,
      _token = token,
      _viewer_login = "alice",
      _auth = {
        read_token = function()
          return token
        end,
      },
    }
    local first = identity.get(p)
    assert.is_nil(vim.inspect(first):find(token, 1, true))
    p._viewer_login = "bob"
    assert.is_not.equals(first.account, identity.get(p).account)
    p._host = "other"
    assert.is_nil(identity.get(p))
    p._verified_host = "other"
    assert.equals("other", identity.get(p).host)
    token = nil
    assert.is_nil(identity.get(p))
  end)
end)
