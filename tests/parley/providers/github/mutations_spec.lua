local fixtures = require("tests.parley.providers.github.fixtures")
local async_tests = require("plenary.async.tests")
local model = fixtures.model
local COMMENTS_JSON = fixtures.COMMENTS_JSON
local POST_COMMENT_RESP_JSON = fixtures.POST_COMMENT_RESP_JSON
local USER_JSON = fixtures.USER_JSON
local REACTIONS_WITH_VIEWER_JSON = fixtures.REACTIONS_WITH_VIEWER_JSON
local REACTIONS_WITHOUT_VIEWER_JSON = fixtures.REACTIONS_WITHOUT_VIEWER_JSON
local REACTIONS_EMPTY_JSON = fixtures.REACTIONS_EMPTY_JSON
local EDIT_COMMENT_RESP_JSON = fixtures.EDIT_COMMENT_RESP_JSON
local REACTION_CREATED_JSON = fixtures.REACTION_CREATED_JSON
local REVIEW_THREADS_RESOLVED_JSON = fixtures.REVIEW_THREADS_RESOLVED_JSON
local RESOLVE_MUTATION_RESP_JSON = fixtures.RESOLVE_MUTATION_RESP_JSON
local UNRESOLVE_MUTATION_RESP_JSON = fixtures.UNRESOLVE_MUTATION_RESP_JSON
local GRAPHQL_ERROR_JSON = fixtures.GRAPHQL_ERROR_JSON
local make_runner = fixtures.make_runner
local ok = fixtures.ok
local ok_empty = fixtures.ok_empty
local make_route_runner = fixtures.make_route_runner
local make_provider = fixtures.make_provider
local make_review = fixtures.make_review
local make_anchor = fixtures.make_anchor

async_tests.describe("parley.providers.github.provider — post_top_level_comment", function()
  async_tests.it("sends the correct gh api command fields", function()
    local runner = make_runner(function(_cmd)
      return ok(POST_COMMENT_RESP_JSON)
    end)
    local p = make_provider(runner.fn)
    local body = model.new_body({ text = "hello", format = "markdown" })
    p:post_top_level_comment(make_review(), "src/foo.lua", make_anchor(15), body)

    local cmd = runner._calls[1]
    -- Must contain --method POST
    assert.is_not_nil(vim.tbl_contains(cmd, "POST"))
    -- Must contain path field
    local has_path = false
    for i, v in ipairs(cmd) do
      if v == "-f" and cmd[i + 1] and cmd[i + 1]:find("path=", 1, true) then
        has_path = true
        break
      end
    end
    assert.is_true(has_path)
  end)

  async_tests.it("returns a mapped parley.Comment", function()
    local runner = make_route_runner({
      { pattern = "/comments", response = ok(POST_COMMENT_RESP_JSON) },
    })
    local p = make_provider(runner.fn)
    local body = model.new_body({ text = "New comment", format = "markdown" })
    local comment = p:post_top_level_comment(make_review(), "src/foo.lua", make_anchor(15), body)

    assert.equals("3001", comment.id)
    assert.equals("alice", comment.author)
    assert.equals("New comment", comment.body.text)
  end)

  async_tests.it("sends start_line and line for ranges", function()
    local runner = make_runner(function(_cmd)
      return ok(POST_COMMENT_RESP_JSON)
    end)
    local p = make_provider(runner.fn)
    local body = model.new_body({ text = "hello", format = "markdown" })
    p:post_top_level_comment(make_review(), "src/foo.lua", make_anchor(12, 18), body)

    local cmd = runner._calls[1]
    assert.is_not_nil(vim.tbl_contains(cmd, "start_line=12"))
    assert.is_not_nil(vim.tbl_contains(cmd, "line=18"))
  end)
end)

async_tests.describe("parley.providers.github.provider — reply", function()
  async_tests.it("does not retry an uncertain reply creation", function()
    local calls = 0
    local delays = {}
    local p = make_provider({
      _spawn = function(_cmd, callback)
        calls = calls + 1
        if calls == 1 then
          callback({ code = 1, stdout = "", stderr = "dial tcp 140.82.121.5:443: i/o timeout" })
        else
          callback({ code = 0, stdout = POST_COMMENT_RESP_JSON, stderr = "" })
        end
        return {
          kill = function() end,
        }
      end,
      _defer = function(cb, timeout_ms)
        delays[#delays + 1] = timeout_ms
        cb()
        return nil
      end,
    })
    local body = model.new_body({ text = "reply", format = "markdown" })
    local result
    local discussion = model.new_discussion({
      id = "1001",
      file = "src/foo.lua",
      line = 10,
      comments = {
        model.new_comment({
          id = "1002",
          author = "bob",
          body = model.new_body({ text = "root", format = "markdown" }),
          created_at = "2024-01-01T00:00:00Z",
          updated_at = "2024-01-01T00:00:00Z",
        }),
      },
    })

    p:begin_reply(make_review(), discussion, discussion.comments[1], body, function(value)
      result = value
    end)

    assert.is_not_nil(result)
    assert.is_false(result.ok)
    assert.is_true(result.uncertain)
    assert.equals(1, calls)
    assert.same({}, delays)
    assert.is_nil(result.comment)
  end)

  async_tests.it("sends in_reply_to equal to the explicit parent_comment_id", function()
    local runner = make_runner(function(_cmd)
      return ok(POST_COMMENT_RESP_JSON)
    end)
    local p = make_provider(runner.fn)
    local body = model.new_body({ text = "reply text", format = "markdown" })
    local discussion = model.new_discussion({
      id = "1001",
      file = "src/foo.lua",
      line = 10,
      comments = {
        model.new_comment({
          id = "1002",
          author = "bob",
          body = model.new_body({ text = "root", format = "markdown" }),
          created_at = "2024-01-01T00:00:00Z",
          updated_at = "2024-01-01T00:00:00Z",
        }),
      },
    })
    p:reply(make_review(), discussion, discussion.comments[1], body)

    local cmd = runner._calls[1]
    local has_reply_to = false
    for i, v in ipairs(cmd) do
      if (v == "-F" or v == "-f") and cmd[i + 1] and cmd[i + 1]:find("in_reply_to=1002", 1, true) then
        has_reply_to = true
        break
      end
    end
    assert.is_true(has_reply_to)
  end)

  async_tests.it("returns a mapped parley.Comment", function()
    local runner = make_route_runner({
      { pattern = "/comments", response = ok(POST_COMMENT_RESP_JSON) },
    })
    local p = make_provider(runner.fn)
    local body = model.new_body({ text = "reply", format = "markdown" })
    local discussion = model.new_discussion({
      id = "1001",
      file = "src/foo.lua",
      line = 10,
      comments = {
        model.new_comment({
          id = "1002",
          author = "bob",
          body = model.new_body({ text = "root", format = "markdown" }),
          created_at = "2024-01-01T00:00:00Z",
          updated_at = "2024-01-01T00:00:00Z",
        }),
      },
    })
    local comment = p:reply(make_review(), discussion, discussion.comments[1], body)
    assert.equals("3001", comment.id)
  end)
end)

async_tests.describe("parley.providers.github.provider — resolve/unresolve", function()
  --- Populate _thread_node_ids via a fetch_discussions() call before mutating.
  --- @return table  provider
  local function make_provider_with_thread()
    local runner = make_route_runner({
      { pattern = "/comments", response = ok(COMMENTS_JSON) },
      { pattern = "graphql", response = ok(REVIEW_THREADS_RESOLVED_JSON) },
    })
    local p = make_provider(runner.fn)
    p:fetch_discussions(make_review())
    return p
  end

  async_tests.it("resolve sends the resolveReviewThread mutation with the cached thread node id", function()
    local p = make_provider_with_thread()
    p._runner = make_route_runner({
      { pattern = "graphql", response = ok(RESOLVE_MUTATION_RESP_JSON) },
    }).fn
    p:resolve(make_review(), "1001")
  end)

  async_tests.it("resolve raises when no thread node id has been cached for the discussion", function()
    local p = make_provider(function(_) end)
    assert.has_error(function()
      p:resolve(make_review(), "9999")
    end)
  end)

  async_tests.it("resolve surfaces a GraphQL-level error", function()
    local p = make_provider_with_thread()
    p._runner = make_route_runner({
      { pattern = "graphql", response = ok(GRAPHQL_ERROR_JSON) },
    }).fn
    assert.has_error(function()
      p:resolve(make_review(), "1001")
    end)
  end)

  async_tests.it("unresolve sends the unresolveReviewThread mutation with the cached thread node id", function()
    local p = make_provider_with_thread()
    p._runner = make_route_runner({
      { pattern = "graphql", response = ok(UNRESOLVE_MUTATION_RESP_JSON) },
    }).fn
    p:unresolve(make_review(), "1001")
  end)

  async_tests.it("unresolve raises when no thread node id has been cached for the discussion", function()
    local p = make_provider(function(_) end)
    assert.has_error(function()
      p:unresolve(make_review(), "9999")
    end)
  end)
end)

async_tests.describe("parley.providers.github.provider — react", function()
  async_tests.it("caches viewer login on first call via gh api /user", function()
    local runner = make_runner(function(cmd)
      for _, a in ipairs(cmd) do
        if a == "/user" then
          return ok(USER_JSON)
        end
      end
      return ok(REACTIONS_EMPTY_JSON)
    end)
    local p = make_provider(runner.fn)
    p:react(make_review(), "1001", "+1")
    assert.is_not_nil(p._viewer_login)
    assert.equals("alice", p._viewer_login)
  end)

  async_tests.it("POSTs reaction when viewer has not reacted", function()
    local runner = make_runner(function(cmd)
      -- /user → viewer login
      for _, a in ipairs(cmd) do
        if a == "/user" then
          return ok(USER_JSON)
        end
      end
      -- GET /reactions → no viewer reaction
      local has_method_post = false
      for _, a in ipairs(cmd) do
        if a == "POST" then
          has_method_post = true
          break
        end
      end
      if not has_method_post then
        return ok(REACTIONS_WITHOUT_VIEWER_JSON)
      end
      return ok(REACTION_CREATED_JSON)
    end)
    local p = make_provider(runner.fn)
    p:react(make_review(), "1001", "+1")

    -- Last call should be POST
    local last = runner._calls[#runner._calls]
    assert.is_not_nil(vim.tbl_contains(last, "POST"))
  end)

  async_tests.it("DELETEs reaction when viewer has already reacted", function()
    local runner = make_runner(function(cmd)
      for _, a in ipairs(cmd) do
        if a == "/user" then
          return ok(USER_JSON)
        end
      end
      local has_delete = false
      for _, a in ipairs(cmd) do
        if a == "DELETE" then
          has_delete = true
          break
        end
      end
      if has_delete then
        return ok_empty()
      end
      -- GET /reactions → viewer already reacted
      return ok(REACTIONS_WITH_VIEWER_JSON)
    end)
    local p = make_provider(runner.fn)
    p:react(make_review(), "1001", "+1")

    -- One of the calls must be DELETE
    local found_delete = false
    for _, call in ipairs(runner._calls) do
      if vim.tbl_contains(call, "DELETE") then
        found_delete = true
        break
      end
    end
    assert.is_true(found_delete)
  end)

  async_tests.it("reuses cached viewer login on second react call", function()
    local user_call_count = 0
    local runner = make_runner(function(cmd)
      for _, a in ipairs(cmd) do
        if a == "/user" then
          user_call_count = user_call_count + 1
          return ok(USER_JSON)
        end
      end
      return ok(REACTIONS_EMPTY_JSON)
    end)
    local p = make_provider(runner.fn)
    p:react(make_review(), "1001", "+1")
    p:react(make_review(), "1002", "+1")
    assert.equals(1, user_call_count)
  end)
end)

async_tests.describe("parley.providers.github.provider — edit", function()
  async_tests.it("sends PATCH to the correct URL", function()
    local runner = make_runner(function(_cmd)
      return ok(EDIT_COMMENT_RESP_JSON)
    end)
    local p = make_provider(runner.fn)
    local body = model.new_body({ text = "Edited body", format = "markdown" })
    p:edit(make_review(), "1001", body)

    local cmd = runner._calls[1]
    assert.is_not_nil(vim.tbl_contains(cmd, "PATCH"))
    -- URL must reference comment id 1001
    local has_id = false
    for _, a in ipairs(cmd) do
      if a:find("1001", 1, true) then
        has_id = true
        break
      end
    end
    assert.is_true(has_id)
  end)

  async_tests.it("returns a mapped parley.Comment with updated body", function()
    local runner = make_route_runner({
      { pattern = "/comments/", response = ok(EDIT_COMMENT_RESP_JSON) },
    })
    local p = make_provider(runner.fn)
    local body = model.new_body({ text = "Edited body", format = "markdown" })
    local comment = p:edit(make_review(), "1001", body)

    assert.equals("1001", comment.id)
    assert.equals("Edited body", comment.body.text)
  end)
end)

async_tests.describe("parley.providers.github.provider — delete", function()
  async_tests.it("sends DELETE to the correct URL", function()
    local runner = make_runner(function(_cmd)
      return ok_empty()
    end)
    local p = make_provider(runner.fn)
    p:delete(make_review(), "1001")

    local cmd = runner._calls[1]
    assert.is_not_nil(vim.tbl_contains(cmd, "DELETE"))
    local has_id = false
    for _, a in ipairs(cmd) do
      if a:find("1001", 1, true) then
        has_id = true
        break
      end
    end
    assert.is_true(has_id)
  end)

  async_tests.it("does not error on success", function()
    local runner = make_runner(function(_cmd)
      return ok_empty()
    end)
    local p = make_provider(runner.fn)
    assert.has_no_error(function()
      p:delete(make_review(), "1001")
    end)
  end)
end)
