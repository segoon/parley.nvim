local arcanum = require("parley.providers.arcanum.provider")
local transport = require("parley.providers.arcanum.transport")
describe("verified Arcanum accounts", function()
  local saved, p, token, calls, response
  before_each(function()
    saved = transport.http_run
    token, calls, response = "SECRET-OAUTH-VALUE", {}, { name = "api-user" }
    p = arcanum.new({
      login = "arc-user",
      _auth = {
        read_token = function()
          return token
        end,
      },
    })
    transport.http_run = function(_, method, path)
      calls[#calls + 1] = { method, path }
      if path == "/v2/users/me?fields=name" then
        if type(response) == "function" then
          return response()
        end
        return response
      end
      return {
        { id = 1, user = { name = "api-user" }, content = "own", created_at = "now" },
        { id = 2, user = { name = "arc-user" }, content = "not own", created_at = "now" },
      }
    end
  end)
  after_each(function()
    transport.http_run = saved
  end)
  it("verifies before mapping ownership and reuses only the same verified credential", function()
    assert.is_nil(p:cache_identity())
    local threads = p:fetch_discussions({ write_context = { pr_id = 1 } })
    assert.equals("/v2/users/me?fields=name", calls[1][2])
    assert.is_true(threads[1].comments[1].is_own)
    assert.is_false(threads[2].comments[1].is_own)
    assert.equals("arc-user", p._arc_login)
    assert.equals("api-user", p._viewer_login)
    assert.is_not_nil(p:cache_identity())
    p:prepare()
    assert.equals(2, #calls)
  end)
  it("fails loading instead of falling back to the local Arc identity", function()
    for _, invalid in ipairs({ {}, vim.NIL, { name = vim.NIL }, { name = " " } }) do
      response = invalid
      assert.has_error(function()
        p:fetch_discussions({ write_context = { pr_id = 1 } })
      end)
      assert.is_nil(p._viewer_login)
      assert.is_nil(p:cache_identity())
    end
    assert.equals(4, #calls)
  end)
  it("discards verification when credentials change during HTTP", function()
    response = function()
      token = "replacement"
      return { name = "old-user" }
    end
    assert.has_error(function()
      p:prepare()
    end)
    assert.is_nil(p:cache_identity())
    assert.is_nil(p._viewer_login)
  end)
  it("invalidates ownership and scopes when credentials rotate", function()
    p:prepare()
    local first = p:cache_identity()
    token = "replacement"
    assert.is_nil(p:cache_identity())
    assert.has_error(function()
      p:delete({}, "1")
    end)
    response = { name = "new-user" }
    p:prepare()
    assert.is_not.equals(first.account, p:cache_identity().account)
    assert.equals("new-user", p._viewer_login)
    assert.is_nil(vim.inspect(p:cache_identity()):find(token, 1, true))
  end)
  it("shares verified account identity across local Arc logins and rejects old ownership cache keys", function()
    p:prepare()
    local other = arcanum.new({ login = "another-checkout-user", _auth = p._auth })
    other:prepare()
    assert.same(p:cache_identity(), other:cache_identity())
    local legacy = vim.fn.sha256(vim.json.encode({ token, "api-user" }))
    assert.is_not.equals(legacy, p:cache_identity().account)
  end)
  it("does not expose server errors containing credentials", function()
    response = function()
      error(token)
    end
    local ok, err = pcall(p.prepare, p)
    assert.is_false(ok)
    assert.is_nil(tostring(err):find(token, 1, true))
  end)
end)
