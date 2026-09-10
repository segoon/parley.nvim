local identity = require("parley.providers.github.cache_identity")

describe("GitHub cache identity", function()
  it("fingerprints credentials and local viewer context without API calls", function()
    local token, login = "SECRET", "alice"
    local p = {
      _host = "host",
      _api_base = "endpoint",
      _owner = "o",
      _repo = "r",
      _auth = {
        read_token = function()
          return token
        end,
      },
      _runner = function(cmd)
        assert.equals("config", cmd[2])
        return { code = 0, stdout = login }
      end,
    }
    local first = identity.get(p)
    assert.is_nil(vim.inspect(first):find(token, 1, true))
    login = "bob"
    assert.is_not.equals(first.account, identity.get(p).account)
    token = "OTHER"
    assert.is_not.equals(first.account, identity.get(p).account)
  end)
  it("uses local CLI credentials then disables caching when unavailable", function()
    local available = true
    local p = {
      _host = "host",
      _api_base = "endpoint",
      _owner = "o",
      _repo = "r",
      _auth = {
        read_token = function()
          return nil
        end,
      },
      _runner = function(cmd)
        assert.is_false(cmd[2] == "api")
        return { code = available and 0 or 1, stdout = "SECRET" }
      end,
    }
    assert.is_not_nil(identity.get(p))
    available = false
    assert.is_nil(identity.get(p))
  end)
end)
