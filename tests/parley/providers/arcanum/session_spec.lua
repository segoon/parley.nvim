local arcanum = require("parley.providers.arcanum.provider")
local transport = require("parley.providers.arcanum.transport")
describe("Arc-bound Arcanum sessions", function()
  local saved, p, token, calls
  before_each(function()
    saved = transport.request_run
    token, calls = "SECRET-OAUTH-VALUE", {}
    p = arcanum.new({
      login = "arc-user",
      _auth = {
        read_token = function()
          return token
        end,
      },
    })
    transport.request_run = function(_, method, path)
      calls[#calls + 1] = { method, path }
      assert.is_nil(path:find("users/me", 1, true))
      return {
        { id = 1, user = { name = "arc-user" }, content = "own", created_at = "now" },
        { id = 2, user = { name = "other-user" }, content = "not own", created_at = "now" },
      }
    end
  end)
  after_each(function()
    transport.request_run = saved
  end)
  it("uses Arc login for ownership without an API identity request", function()
    assert.is_nil(p:cache_identity())
    local threads = p:fetch_discussions({ write_context = { pr_id = 1 } })
    assert.is_true(threads[1].comments[1].is_own)
    assert.is_false(threads[2].comments[1].is_own)
    assert.equals("arc-user", p._viewer_login)
    assert.is_not_nil(p:cache_identity())
    p:prepare()
    assert.equals(1, #calls)
  end)
  it("requires a usable Arc login", function()
    for _, login in ipairs({ "", " ", vim.NIL }) do
      p._arc_login = login
      assert.has_error(function()
        p:prepare()
      end)
      assert.is_nil(p:cache_identity())
    end
    assert.equals(0, #calls)
  end)
  it("invalidates sessions when credentials rotate", function()
    p:prepare()
    local first = p:cache_identity()
    token = "replacement"
    assert.is_nil(p:cache_identity())
    assert.has_error(function()
      p:delete({}, "1")
    end)
    p:prepare()
    assert.is_not.equals(first.account, p:cache_identity().account)
    assert.equals("arc-user", p._viewer_login)
    assert.is_nil(vim.inspect(p:cache_identity()):find(token, 1, true))
  end)
  it("isolates Arc logins and invalidates old API-viewer caches", function()
    p:prepare()
    local other = arcanum.new({ login = "another-user", _auth = p._auth })
    other:prepare()
    assert.is_not.equals(p:cache_identity().account, other:cache_identity().account)
    local legacy = vim.fn.sha256(vim.json.encode({ "verified-viewer-review-v4", token, "arc-user" }))
    assert.is_not.equals(legacy, p:cache_identity().account)
    p._arc_login = "new-user"
    assert.is_nil(p:cache_identity())
    p:prepare()
    assert.equals("new-user", p._viewer_login)
  end)
  it("invalidates a changed host before the next request", function()
    p:prepare()
    p._host = "other.example"
    assert.is_nil(p:cache_identity())
    p:prepare()
    assert.equals("other.example", p:cache_identity().host)
  end)
  it("does not expose credential-reader exceptions", function()
    p._auth = {
      read_token = function()
        error(token)
      end,
    }
    local ok, err = pcall(p.prepare, p)
    assert.is_false(ok)
    assert.is_nil(tostring(err):find(token, 1, true))
  end)
end)
