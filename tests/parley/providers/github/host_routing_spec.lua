local a = require("plenary.async.tests")
local github = require("parley.providers.github.provider")
local transport = require("parley.providers.github.transport")

describe("GitHub request routing", function()
  local available, old_host
  before_each(function()
    available, old_host = transport._gh_available, vim.env.GH_HOST
    transport._gh_available, vim.env.GH_HOST = true, "unrelated.example.com"
  end)
  after_each(function()
    transport._gh_available, vim.env.GH_HOST = available, old_host
  end)

  for _, mode in ipairs({ "coroutine", "callback" }) do
    for _, host in ipairs({ "github.com", "ghe.example.com" }) do
      a.it("pins REST and GraphQL " .. mode .. " requests to " .. host, function()
        local commands = {}
        local provider = github.new({
          repository = "owner/repo",
          host = host,
          _runner = function(cmd)
            commands[#commands + 1] = cmd
            return { code = 0, stdout = '{"data":{}}' }
          end,
          _spawn = function(cmd, cb)
            commands[#commands + 1] = cmd
            cb({ code = 0, stdout = '{"data":{}}' })
            return { kill = function() end }
          end,
        })
        local original = { "gh", "api", "--method", "POST", "/repos/owner/repo/pulls/42/comments", "-f", "body=text" }
        local copy = vim.deepcopy(original)
        if mode == "coroutine" then
          transport.gh_run(provider, original)
          transport.gh_graphql(provider, "query { viewer { login } }", {})
        else
          transport.gh_start(provider, original, function() end)
          transport.gh_graphql_start(provider, "mutation { x }", {}, function() end)
        end
        assert.same(copy, original, "Routing must not mutate reusable request arguments")
        assert.equals(2, #commands)
        for _, cmd in ipairs(commands) do
          local index
          for i, arg in ipairs(cmd) do
            if arg == "--hostname" then
              index = i
            end
          end
          assert.is_not_nil(index)
          assert.equals(host, cmd[index + 1])
        end
      end)
    end
  end

  a.it("uses an explicit API base for REST and GraphQL endpoints", function()
    local commands = {}
    local provider = github.new({
      repository = "owner/repo",
      host = "ghe.example.com",
      api_base = "https://ghe.example.com/custom/api/v3/",
      _runner = function(cmd)
        commands[#commands + 1] = cmd
        return { code = 0, stdout = '{"data":{}}' }
      end,
      _spawn = function(cmd, cb)
        commands[#commands + 1] = cmd
        cb({ code = 0, stdout = '{"data":{}}' })
        return { kill = function() end }
      end,
    })
    transport.gh_run(provider, { "gh", "api", "/user" })
    transport.gh_graphql_start(provider, "query { viewer { login } }", {}, function() end)
    assert.is_true(vim.tbl_contains(commands[1], "https://ghe.example.com/custom/api/v3/user"))
    assert.is_true(vim.tbl_contains(commands[2], "https://ghe.example.com/custom/api/graphql"))
  end)
end)
