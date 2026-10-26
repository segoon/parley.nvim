local a = require("plenary.async.tests")
local github = require("parley.providers.github.provider")
local transport = require("parley.providers.github.transport")
local review = { pr = { id = "42" }, write_context = { number = 42 } }

---@param id integer
---@param more? boolean
---@return table
local function page(id, more)
  return {
    data = {
      repository = {
        pullRequest = {
          reviewThreads = {
            nodes = { { id = "thread" .. id, isResolved = true, comments = { nodes = { { databaseId = id } } } } },
            pageInfo = { hasNextPage = more or false, endCursor = "cursor" .. id },
          },
        },
      },
    },
  }
end

a.describe("GitHub pagination", function()
  local available
  a.before_each(function()
    available, transport._gh_available = transport._gh_available, true
  end)
  a.after_each(function()
    transport._gh_available = available
  end)

  a.it("preserves custom GraphQL endpoints with nested variables and cursor traversal", function()
    local calls = 0
    local p = github.new({
      repository = "owner/repo",
      host = "ghe.example.com",
      api_base = "https://ghe.example.com/custom/api/v3",
      _runner = function(cmd)
        if vim.tbl_contains(cmd, "/user") or table.concat(cmd, " "):find("/user", 1, true) then
          return { code = 0, stdout = '{"login":"alice"}' }
        end
        if vim.tbl_contains(cmd, "https://ghe.example.com/custom/api/graphql") then
          calls = calls + 1
          assert.is_false(vim.tbl_contains(cmd, "--paginate"))
          assert.is_true(vim.tbl_contains(cmd, "variables[owner]=owner"))
          assert.is_true(vim.tbl_contains(cmd, "variables[number]=42"))
          if calls == 2 then
            assert.is_true(vim.tbl_contains(cmd, "variables[endCursor]=cursor1"))
          end
          return { code = 0, stdout = vim.json.encode(page(calls, calls == 1)) }
        end
        return { code = 0, stdout = '[[{"id":1,"path":"f","line":1},{"id":2,"path":"f","line":2}]]' }
      end,
    })
    local discussions = p:fetch_discussions(review)
    assert.equals(2, calls)
    assert.is_true(discussions[1].resolved)
    assert.is_true(discussions[2].resolved)
    assert.same({ ["1"] = "thread1", ["2"] = "thread2" }, p._thread_node_ids)
  end)

  a.it("discards partial GraphQL metadata and previous thread IDs on a later-page error", function()
    local broken = false
    local p = github.new({
      repository = "owner/repo",
      _runner = function(cmd)
        if vim.tbl_contains(cmd, "/user") or table.concat(cmd, " "):find("/user", 1, true) then
          return { code = 0, stdout = '{"login":"alice"}' }
        end
        if vim.tbl_contains(cmd, "graphql") then
          local pages = { page(1), broken and { errors = { { message = "denied" } } } or page(2) }
          return { code = 0, stdout = vim.json.encode(pages) }
        end
        return { code = 0, stdout = '[[{"id":1,"path":"f","line":1}]]' }
      end,
    })
    assert.is_true(p:fetch_discussions(review)[1].resolved)
    broken = true
    assert.is_false(p:fetch_discussions(review)[1].resolved)
    assert.same({}, p._thread_node_ids)
    assert.has_error(function()
      p:resolve(review, "1")
    end)
  end)

  a.it("rejects malformed REST pages instead of publishing partial results", function()
    local p = github.new({
      repository = "owner/repo",
      _runner = function()
        return { code = 0, stdout = '[[{"id":1}],{"message":"broken"}]' }
      end,
    })
    assert.has_error(function()
      p:fetch_discussions(review)
    end)
  end)

  a.it("uses later reaction pages", function()
    local deleted
    local p = github.new({
      repository = "owner/repo",
      _runner = function(cmd)
        if vim.tbl_contains(cmd, "DELETE") then
          deleted = cmd
          return { code = 0, stdout = "" }
        end
        local joined = table.concat(cmd, " ")
        if joined:find("/reactions", 1, true) then
          return {
            code = 0,
            stdout = '[[{"id":1,"content":"+1","user":{"login":"bob"}}],'
              .. '[{"id":2,"content":"+1","user":{"login":"alice"}}]]',
          }
        end
        return { code = 0, stdout = '[{"number":42,"head":{"sha":"abc"}}]' }
      end,
    })
    p._viewer_login = "alice"
    p:react(review, "7", "+1")
    assert.is_true(vim.tbl_contains(deleted, "/repos/owner/repo/pulls/comments/7/reactions/2"))
  end)

  a.it("explains the minimum CLI version when slurp is unsupported", function()
    local p = github.new({
      repository = "owner/repo",
      _runner = function()
        return { code = 1, stderr = "unknown flag: --slurp" }
      end,
    })
    local ok, err = pcall(transport.gh_run, p, { "gh", "api", "--paginate", "/comments" })
    assert.is_false(ok)
    assert.matches("upgrade gh", err, 1, true)
  end)
end)
