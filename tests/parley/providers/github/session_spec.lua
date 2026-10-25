local a = require("plenary.async.tests")
local github = require("parley.providers.github.provider")
local transport = require("parley.providers.github.transport")
local await = require("parley.runtime.await")

a.describe("GitHub request sessions", function()
  local available
  a.before_each(function()
    available, transport._gh_available = transport._gh_available, true
  end)
  a.after_each(function()
    transport._gh_available = available
  end)

  for _, method in ipairs({ "GET", "POST" }) do
    a.it("rejects credentials changed during " .. method, function()
      local token, response, result, count = "first", nil, nil, 0
      local p = github.new({
        repository = "owner/repo",
        _auth = {
          read_token_async = function()
            return token
          end,
        },
        _spawn = function(_, cb)
          response = cb
          return { kill = function() end }
        end,
      })
      p:prepare()
      transport.gh_start(p, { "gh", "api", "--method", method, "/comments" }, function(value)
        result, count = value, count + 1
      end)
      token = "second"
      response({ code = 0, stdout = "{}" })
      response({ code = 0, stdout = "{}" })
      assert.equals(1, count)
      assert.is_false(result.ok)
      assert.equals(method == "POST", result.uncertain == true)
      assert.is_nil(p:cache_identity())
    end)
  end

  a.it("does not send after cancellation during credential lookup", function()
    local resume, result, sends, count = nil, nil, 0, 0
    local p = github.new({
      repository = "owner/repo",
      _auth = {
        read_token_async = function()
          return "token"
        end,
      },
      _spawn = function()
        sends = sends + 1
      end,
    })
    p:prepare()
    p._auth.read_token_async = function()
      return await.callback(function(cb)
        resume = cb
      end)
    end
    local handle = transport.gh_start(p, { "gh", "api", "--method", "POST", "/comments" }, function(value)
      result, count = value, count + 1
    end)
    handle.cancel()
    resume("token")
    assert.equals(0, sends)
    assert.equals(1, count)
    assert.is_true(result.cancelled)
    assert.is_nil(result.uncertain)
  end)

  a.it("rejects an old request after a new session is prepared", function()
    local response, result
    local p = github.new({
      repository = "owner/repo",
      _auth = {
        read_token_async = function()
          return "token"
        end,
      },
      _spawn = function(_, cb)
        response = cb
      end,
    })
    p:prepare()
    transport.gh_start(p, { "gh", "api", "/user" }, function(value)
      result = value
    end)
    p:prepare()
    response({ code = 0, stdout = "{}" })
    assert.is_false(result.ok)
    assert.is_not_nil(p:cache_identity())
  end)

  a.it("pins API subprocess credentials to the prepared session", function()
    local p = github.new({
      repository = "owner/repo",
      _auth = {
        read_token_async = function()
          return "selected"
        end,
      },
      _system = function(_, opts, cb)
        assert.equals("selected", opts.env.GH_TOKEN)
        assert.equals("selected", opts.env.GH_ENTERPRISE_TOKEN)
        cb({ code = 0, stdout = "{}" })
      end,
    })
    p:prepare()
    assert.same({}, transport.gh_run(p, { "gh", "api", "/user" }))
  end)
  a.it("completes cancellation once while the response credential check is pending", function()
    local resume, response, result
    local completions = 0
    local p = github.new({
      repository = "owner/repo",
      _auth = {
        read_token_async = function()
          return "token"
        end,
      },
      _spawn = function(_, cb)
        response = cb
      end,
    })
    p:prepare()
    local handle = transport.gh_start(p, { "gh", "api", "--method", "POST", "/comments" }, function(value)
      result, completions = value, completions + 1
    end)
    p._auth.read_token_async = function()
      return await.callback(function(cb)
        resume = cb
      end)
    end
    response({ code = 0, stdout = "{}" })
    handle.cancel()
    assert.is_true(result.cancelled)
    assert.is_true(result.uncertain)
    resume("token")
    assert.equals(1, completions)
  end)
end)
