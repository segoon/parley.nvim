local a = require("plenary.async.tests")
local github = require("parley.providers.github.provider")
local transport = require("parley.providers.github.transport")
local auth = require("parley.providers.github.auth")

a.describe("GitHub CLI delegation", function()
  local available
  a.before_each(function()
    available, transport._gh_available = transport._gh_available, true
  end)
  a.after_each(function()
    transport._gh_available = available
  end)

  a.it("resolves host credentials asynchronously through gh without exposing failures", function()
    local token, err = auth.read_token_async("ghe.example.com", {
      timeout_ms = 321,
      system = function(cmd, opts, cb)
        assert.same({ "gh", "auth", "token", "--hostname", "ghe.example.com" }, cmd)
        assert.equals(321, opts.timeout)
        cb({ code = 0, stdout = " SECRET\n" })
      end,
    })
    assert.equals("SECRET", token)
    assert.is_nil(err)
    token, err = auth.read_token_async("ghe.example.com", {
      system = function(_, _, cb)
        cb({ code = 1, stdout = "SECRET", stderr = "SECRET" })
      end,
    })
    assert.is_nil(token)
    assert.is_nil(err:find("SECRET", 1, true))
    assert.matches("gh auth login", err, 1, true)
  end)

  a.it("uses the callback executor for coroutine reads and ignores duplicate completion", function()
    local calls = 0
    local p = github.new({
      repository = "owner/repo",
      _runner = function()
        error("API requests must use the callback executor")
      end,
      _spawn = function(_, cb)
        calls = calls + 1
        cb({ code = 0, stdout = '{"id":42}' })
        cb({ code = 1, stderr = "late failure" })
        return { kill = function() end }
      end,
    })
    assert.equals(42, transport.gh_run(p, { "gh", "api", "/user" }).id)
    assert.equals(1, calls)
  end)

  a.it("flattens CLI REST pages and consumes CLI GraphQL pages in one invocation", function()
    local calls = {}
    local p = github.new({
      repository = "owner/repo",
      _runner = function(cmd)
        calls[#calls + 1] = cmd
        if cmd[2] == "config" then
          return { code = 0, stdout = "alice" }
        end
        assert.is_true(vim.tbl_contains(cmd, "--paginate"))
        assert.is_true(vim.tbl_contains(cmd, "--slurp"))
        if vim.tbl_contains(cmd, "graphql") then
          local pages = {}
          for i = 1, 2 do
            pages[i] = {
              data = {
                repository = {
                  pullRequest = {
                    reviewThreads = {
                      nodes = {
                        { id = "thread" .. i, isResolved = true, comments = { nodes = { { databaseId = i } } } },
                      },
                    },
                  },
                },
              },
            }
          end
          return { code = 0, stdout = vim.json.encode(pages) }
        end
        return { code = 0, stdout = '[[{"id":1,"path":"f","line":1}],[{"id":2,"path":"f","line":2}]]' }
      end,
    })
    local discussions = p:fetch_discussions({ pr = { id = "42" }, write_context = { number = 42 } })
    assert.equals(2, #discussions)
    assert.is_true(discussions[1].resolved)
    assert.is_true(discussions[2].resolved)
    assert.equals(3, #calls)
  end)

  a.it("prepares identity without blocking cache getters and rejects credential changes", function()
    local token, reads, sends = "first", 0, 0
    local p = github.new({
      repository = "owner/repo",
      _auth = {
        read_token_async = function()
          reads = reads + 1
          return token
        end,
      },
      _spawn = function(_, cb)
        sends = sends + 1
        cb({ code = 0, stdout = "[]" })
        return { kill = function() end }
      end,
    })
    p:prepare()
    local first, count = p:cache_identity(), reads
    assert.is_not_nil(first)
    assert.same(first, p:cache_identity())
    assert.equals(count, reads)
    token = "second"
    local ok = pcall(transport.gh_run, p, { "gh", "api", "--method", "POST", "/comments" })
    assert.is_false(ok)
    assert.equals(0, sends)
    assert.is_nil(p:cache_identity())
    p:prepare()
    assert.is_not.equals(first.account, p:cache_identity().account)
  end)
end)
