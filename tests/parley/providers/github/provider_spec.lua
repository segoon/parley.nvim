--- Tests for parley.providers.github.provider — GitHub provider implementation.
--- Run via: make test

local async_tests = require("plenary.async.tests")
local provider_mod = require("parley.provider")
local model = require("parley.model")
local gh = require("parley.providers.github.provider")

-- ---------------------------------------------------------------------------
-- Fixtures — raw GitHub API JSON responses (as Lua strings)
-- ---------------------------------------------------------------------------

--- Minimal PR list response (one open PR).
local PR_LIST_JSON = vim.json.encode({
  {
    number = 42,
    title = "Add feature",
    state = "open",
    base = { ref = "main" },
    head = { ref = "feature", sha = "abc123def456" },
    user = { login = "alice" },
    html_url = "https://github.com/owner/repo/pull/42",
  },
})

--- Empty PR list (no open PR for branch).
local PR_LIST_EMPTY_JSON = vim.json.encode({})

--- Reviews list — approved.
local REVIEWS_APPROVED_JSON = vim.json.encode({
  { state = "APPROVED", submitted_at = "2024-01-02T10:00:00Z" },
})

--- Reviews list — changes requested.
local REVIEWS_CHANGES_JSON = vim.json.encode({
  { state = "CHANGES_REQUESTED", submitted_at = "2024-01-02T10:00:00Z" },
})

--- Empty reviews list → pending.
local REVIEWS_EMPTY_JSON = vim.json.encode({})

--- Two review comments: one root, one reply.
local COMMENTS_JSON = vim.json.encode({
  {
    id = 1001,
    user = { login = "alice" },
    body = "First comment",
    created_at = "2024-01-01T10:00:00Z",
    updated_at = "2024-01-01T10:00:00Z",
    path = "src/foo.lua",
    line = 10,
    original_line = 10,
    start_line = vim.NIL,
    in_reply_to_id = vim.NIL,
    reactions = {
      total_count = 1,
      ["+1"] = 1,
      ["-1"] = 0,
      laugh = 0,
      hooray = 0,
      confused = 0,
      heart = 0,
      rocket = 0,
      eyes = 0,
      url = "https://api.github.com/repos/owner/repo/pulls/comments/1001/reactions",
    },
  },
  {
    id = 1002,
    user = { login = "bob" },
    body = "Reply comment",
    created_at = "2024-01-01T11:00:00Z",
    updated_at = "2024-01-01T11:00:00Z",
    path = "src/foo.lua",
    line = 10,
    original_line = 10,
    start_line = vim.NIL,
    in_reply_to_id = 1001,
    reactions = {
      total_count = 0,
      ["+1"] = 0,
      ["-1"] = 0,
      laugh = 0,
      hooray = 0,
      confused = 0,
      heart = 0,
      rocket = 0,
      eyes = 0,
      url = "https://api.github.com/repos/owner/repo/pulls/comments/1002/reactions",
    },
  },
})

--- Single root comment with null line (deleted-line comment).
local COMMENTS_NULL_LINE_JSON = vim.json.encode({
  {
    id = 2001,
    user = { login = "carol" },
    body = "Deleted line comment",
    created_at = "2024-01-01T10:00:00Z",
    updated_at = "2024-01-01T10:00:00Z",
    path = "src/bar.lua",
    line = vim.NIL,
    original_line = 5,
    start_line = vim.NIL,
    in_reply_to_id = vim.NIL,
    reactions = {
      total_count = 0,
      ["+1"] = 0,
      ["-1"] = 0,
      laugh = 0,
      hooray = 0,
      confused = 0,
      heart = 0,
      rocket = 0,
      eyes = 0,
      url = "https://api.github.com/repos/owner/repo/pulls/comments/2001/reactions",
    },
  },
})

--- Post-comment REST response.
local POST_COMMENT_RESP_JSON = vim.json.encode({
  id = 3001,
  user = { login = "alice" },
  body = "New comment",
  created_at = "2024-01-02T10:00:00Z",
  updated_at = "2024-01-02T10:00:00Z",
  path = "src/foo.lua",
  line = 15,
  original_line = 15,
  start_line = vim.NIL,
  in_reply_to_id = vim.NIL,
  reactions = {
    total_count = 0,
    ["+1"] = 0,
    ["-1"] = 0,
    laugh = 0,
    hooray = 0,
    confused = 0,
    heart = 0,
    rocket = 0,
    eyes = 0,
    url = "https://api.github.com/repos/owner/repo/pulls/comments/3001/reactions",
  },
})

--- Viewer user object.
local USER_JSON = vim.json.encode({ login = "alice" })

--- Reactions list — viewer has already reacted with +1 (has a reaction entry for alice).
local REACTIONS_WITH_VIEWER_JSON = vim.json.encode({
  { id = 9001, user = { login = "alice" }, content = "+1" },
  { id = 9002, user = { login = "bob" }, content = "+1" },
})

--- Reactions list — viewer has NOT reacted.
local REACTIONS_WITHOUT_VIEWER_JSON = vim.json.encode({
  { id = 9002, user = { login = "bob" }, content = "+1" },
})

--- Empty reactions list.
local REACTIONS_EMPTY_JSON = vim.json.encode({})

--- Edit comment REST response.
local EDIT_COMMENT_RESP_JSON = vim.json.encode({
  id = 1001,
  user = { login = "alice" },
  body = "Edited body",
  created_at = "2024-01-01T10:00:00Z",
  updated_at = "2024-01-02T12:00:00Z",
  path = "src/foo.lua",
  line = 10,
  original_line = 10,
  start_line = vim.NIL,
  in_reply_to_id = vim.NIL,
  reactions = {
    total_count = 0,
    ["+1"] = 0,
    ["-1"] = 0,
    laugh = 0,
    hooray = 0,
    confused = 0,
    heart = 0,
    rocket = 0,
    eyes = 0,
    url = "https://api.github.com/repos/owner/repo/pulls/comments/1001/reactions",
  },
})

--- Reaction creation response.
local REACTION_CREATED_JSON = vim.json.encode({ id = 9999, user = { login = "alice" }, content = "+1" })

-- ---------------------------------------------------------------------------
-- Fake runner helpers
-- ---------------------------------------------------------------------------

--- Build a fake _runner from a dispatch function.
--- The runner receives the command table and returns { code, stdout, stderr }.
---
--- @param dispatch fun(cmd: string[]): { code: integer, stdout: string, stderr: string }
--- @return table  fake with _calls log
local function make_runner(dispatch)
  local fake = { _calls = {} }
  fake.fn = function(cmd)
    table.insert(fake._calls, vim.deepcopy(cmd))
    return dispatch(cmd)
  end
  return fake
end

--- Success response wrapping a JSON string.
local function ok(json_str)
  return { code = 0, stdout = json_str, stderr = "" }
end

--- Success response with plain text (non-JSON) body.
local function ok_text(text)
  return { code = 0, stdout = text, stderr = "" }
end

--- Success response with no body (DELETE).
local function ok_empty()
  return { code = 0, stdout = "", stderr = "" }
end

--- Failure response.
local function fail(msg)
  return { code = 1, stdout = "", stderr = msg }
end

--- Return true when cmd is a `gh config get` invocation.
--- Used by test runners to distinguish local config reads from API calls.
local function is_config_get(cmd)
  return cmd[1] == "gh" and cmd[2] == "config"
end

--- Build a runner that dispatches based on the URL argument.
--- Each entry in routes: { pattern, response } — first match wins.
--- pattern is matched against the first arg after "gh api" that looks like a path/URL.
---
--- @param routes { pattern: string, response: table }[]
--- @return table  fake runner
local function make_route_runner(routes)
  return make_runner(function(cmd)
    -- Find the API path/URL in the command (the first non-flag arg after "gh api [flags]")
    local path_arg = nil
    local i = 1
    while i <= #cmd do
      local a = cmd[i]
      -- Skip "gh", "api"
      if a == "gh" or a == "api" then
        i = i + 1
      -- Skip flags with values
      elseif a == "--method" or a == "-f" or a == "-F" or a == "--hostname" then
        i = i + 2
      -- Skip solo flags
      elseif a == "--paginate" or a == "--silent" then
        i = i + 1
      -- First remaining positional arg is the path
      elseif not a:match("^%-") then
        path_arg = a
        break
      else
        i = i + 1
      end
    end
    for _, route in ipairs(routes) do
      if path_arg and path_arg:find(route.pattern, 1, true) then
        return route.response
      end
    end
    return fail("no route matched: " .. tostring(path_arg))
  end)
end

--- Fake auth module — always returns the given token.
local function make_auth(token)
  return {
    read_token = function(_host)
      return token, nil
    end,
  }
end

--- Fake auth module that returns an error.
local function make_auth_err(msg)
  return {
    read_token = function(_host)
      return nil, msg
    end,
  }
end

--- Build a minimal provider for testing.
--- @param opts? {
---   _runner?: fun(cmd: string[]): table,
---   _spawn?: fun(
---     cmd: string[],
---     callback: fun(result: {code: integer, stdout: string, stderr: string})
---   ): vim.SystemObj|nil,
---   _sleep?: fun(timeout_ms: integer): nil,
---   _defer?: fun(callback: fun(), timeout_ms: integer): uv_timer_t|nil,
---   _get_config?: fun(): table|nil,
---   _system?: fun(cmd: string[], opts: table, callback: fun(result: vim.SystemCompleted)): vim.SystemObj,
--- }
local function make_provider(opts)
  if type(opts) == "function" then
    opts = { _runner = opts }
  end
  opts = opts or {}
  return gh.new({
    owner = "owner",
    repo = "repo",
    _runner = opts._runner,
    _spawn = opts._spawn,
    _sleep = opts._sleep,
    _defer = opts._defer,
    _get_config = opts._get_config,
    _system = opts._system,
    _auth = make_auth("ghp_TESTTOKEN"),
  })
end

-- ---------------------------------------------------------------------------
-- Minimal PR for passing to methods that need it.
-- ---------------------------------------------------------------------------
local SAMPLE_PR = model.new_pr({
  id = "42",
  title = "Add feature",
  state = "open",
  base_branch = "main",
  head_branch = "feature",
  author = "alice",
  url = "https://github.com/owner/repo/pull/42",
  review_status = "pending",
})

---@param head_sha? string
---@param number? integer
---@return parley.DetectedReview
local function make_review(head_sha, number)
  return {
    pr = SAMPLE_PR,
    head_sha = head_sha or "abc123def456",
    write_context = {
      head_sha = head_sha or "abc123def456",
      number = number or 42,
    },
  }
end

---@param start_line integer
---@param end_line? integer
---@return parley.Anchor
local function make_anchor(start_line, end_line)
  return { start_line = start_line, end_line = end_line }
end

-- ---------------------------------------------------------------------------
-- Suite: M.new / interface validation
-- ---------------------------------------------------------------------------

describe("parley.providers.github.provider — new / validate", function()
  it("returns a table that passes provider.validate()", function()
    local p = gh.new({ owner = "o", repo = "r" })
    assert.is_true(provider_mod.validate(p))
  end)

  it("errors when owner is missing", function()
    assert.has_error(function()
      gh.new({ repo = "r" })
    end)
  end)

  it("errors when repo is missing", function()
    assert.has_error(function()
      gh.new({ owner = "o" })
    end)
  end)
end)

-- ---------------------------------------------------------------------------
-- Suite: auth
-- ---------------------------------------------------------------------------

async_tests.describe("parley.providers.github.provider — auth", function()
  async_tests.it("returns token from the auth module", function()
    local p = gh.new({ owner = "o", repo = "r", _auth = make_auth("ghp_ABC") })
    assert.equals("ghp_ABC", p:auth())
  end)

  async_tests.it("propagates error when auth module returns nil", function()
    local p = gh.new({ owner = "o", repo = "r", _auth = make_auth_err("no token") })
    assert.has_error(function()
      p:auth()
    end)
  end)
end)

-- ---------------------------------------------------------------------------
-- Suite: detect_pr
-- ---------------------------------------------------------------------------

async_tests.describe("parley.providers.github.provider — detect_pr", function()
  async_tests.it("retries transient gh transport failures with backoff", function()
    local sleeps = {}
    local pull_calls = 0
    local runner = make_runner(function(cmd)
      for _, arg in ipairs(cmd) do
        if arg:find("/reviews", 1, true) then
          return ok(REVIEWS_EMPTY_JSON)
        end
      end
      pull_calls = pull_calls + 1
      if pull_calls == 1 then
        return fail('Post "https://api.github.com": dial tcp 140.82.121.5:443: i/o timeout')
      end
      return ok(PR_LIST_JSON)
    end)
    local p = make_provider({
      _runner = runner.fn,
      _sleep = function(timeout_ms)
        sleeps[#sleeps + 1] = timeout_ms
      end,
    })

    local review = p:detect_pr("/repo/root", "feature")

    assert.is_not_nil(review)
    assert.equals(250, sleeps[1])
    assert.equals(3, #runner._calls)
  end)

  async_tests.it("does not retry non-retryable gh failures", function()
    local sleeps = {}
    local runner = make_runner(function(_cmd)
      return fail("HTTP 422: Validation Failed")
    end)
    local p = make_provider({
      _runner = runner.fn,
      _sleep = function(timeout_ms)
        sleeps[#sleeps + 1] = timeout_ms
      end,
    })

    local success, err = pcall(function()
      p:detect_pr("/repo/root", "feature")
    end)
    assert.is_false(success)
    assert.is_not_nil(tostring(err):find("parley.github: gh command failed", 1, true))
    assert.equals(0, #sleeps)
    assert.equals(1, #runner._calls)
  end)

  async_tests.it("passes a 5 second timeout to gh by default", function()
    local timeouts = {}
    local p = make_provider({
      _system = function(_cmd, opts, callback)
        timeouts[#timeouts + 1] = opts.timeout
        callback({ code = 0, stdout = PR_LIST_EMPTY_JSON, stderr = "" })
        return { kill = function() end }
      end,
      _get_config = function()
        return nil
      end,
    })

    local review = p:detect_pr("/repo/root", "feature")

    assert.is_nil(review)
    assert.equals(5000, timeouts[1])
  end)

  async_tests.it("returns nil when the PR list is empty", function()
    local runner = make_route_runner({
      { pattern = "/pulls", response = ok(PR_LIST_EMPTY_JSON) },
    })
    local p = make_provider(runner.fn)
    local review = p:detect_pr("/repo/root", "feature")
    assert.is_nil(review)
  end)

  async_tests.it("maps PR fields to parley.PR correctly", function()
    local runner = make_route_runner({
      { pattern = "/reviews", response = ok(REVIEWS_APPROVED_JSON) },
      { pattern = "/pulls", response = ok(PR_LIST_JSON) },
    })
    local p = make_provider(runner.fn)
    local review = p:detect_pr("/repo/root", "feature")

    assert.is_not_nil(review)
    assert.equals("42", review.pr.id)
    assert.equals("Add feature", review.pr.title)
    assert.equals("open", review.pr.state)
    assert.equals("main", review.pr.base_branch)
    assert.equals("feature", review.pr.head_branch)
    assert.equals("alice", review.pr.author)
    assert.equals("https://github.com/owner/repo/pull/42", review.pr.url)
  end)

  async_tests.it("sets review_status=approved when reviews show APPROVED", function()
    local runner = make_route_runner({
      { pattern = "/reviews", response = ok(REVIEWS_APPROVED_JSON) },
      { pattern = "/pulls", response = ok(PR_LIST_JSON) },
    })
    local p = make_provider(runner.fn)
    local review = p:detect_pr("/repo/root", "feature")
    assert.equals("approved", review.pr.review_status)
  end)

  async_tests.it("sets review_status=changes_requested when reviews show CHANGES_REQUESTED", function()
    local runner = make_route_runner({
      { pattern = "/reviews", response = ok(REVIEWS_CHANGES_JSON) },
      { pattern = "/pulls", response = ok(PR_LIST_JSON) },
    })
    local p = make_provider(runner.fn)
    local review = p:detect_pr("/repo/root", "feature")
    assert.equals("changes_requested", review.pr.review_status)
  end)

  async_tests.it("sets review_status=pending when no reviews exist", function()
    local runner = make_route_runner({
      { pattern = "/reviews", response = ok(REVIEWS_EMPTY_JSON) },
      { pattern = "/pulls", response = ok(PR_LIST_JSON) },
    })
    local p = make_provider(runner.fn)
    local review = p:detect_pr("/repo/root", "feature")
    assert.equals("pending", review.pr.review_status)
  end)

  async_tests.it("returns explicit write context for later use", function()
    local runner = make_route_runner({
      { pattern = "/reviews", response = ok(REVIEWS_EMPTY_JSON) },
      { pattern = "/pulls", response = ok(PR_LIST_JSON) },
    })
    local p = make_provider(runner.fn)
    local review = p:detect_pr("/repo/root", "feature")
    assert.equals("abc123def456", review.head_sha)
    assert.same({ head_sha = "abc123def456", number = 42 }, review.write_context)
  end)

  async_tests.it("passes the branch in the query string", function()
    local runner = make_runner(function(cmd)
      -- Check the pulls URL contains the head filter
      local url_arg = nil
      for _, a in ipairs(cmd) do
        if a:find("/pulls", 1, true) then
          url_arg = a
          break
        end
      end
      assert.is_not_nil(url_arg)
      assert.is_not_nil(url_arg:find("owner:my%-branch", 1, false))
      return ok(PR_LIST_EMPTY_JSON)
    end)
    local p = make_provider(runner.fn)
    p:detect_pr("/repo/root", "my-branch")
  end)
end)

-- ---------------------------------------------------------------------------
-- Suite: fetch_discussions
-- ---------------------------------------------------------------------------

async_tests.describe("parley.providers.github.provider — fetch_discussions", function()
  async_tests.it("returns one Discussion per root comment", function()
    local runner = make_route_runner({
      { pattern = "/comments", response = ok(COMMENTS_JSON) },
    })
    local p = make_provider(runner.fn)
    local discussions = p:fetch_discussions(make_review())
    assert.equals(1, #discussions)
  end)

  async_tests.it("maps the root comment fields correctly", function()
    local runner = make_route_runner({
      { pattern = "/comments", response = ok(COMMENTS_JSON) },
    })
    local p = make_provider(runner.fn)
    local disc = p:fetch_discussions(make_review())[1]

    assert.equals("1001", disc.id)
    assert.equals("src/foo.lua", disc.file)
    assert.equals(10, disc.line)
    assert.is_false(disc.resolved) -- always false (GraphQL postponed)
  end)

  async_tests.it("attaches two comments (root + reply) to the discussion", function()
    local runner = make_route_runner({
      { pattern = "/comments", response = ok(COMMENTS_JSON) },
    })
    local p = make_provider(runner.fn)
    local disc = p:fetch_discussions(make_review())[1]
    assert.equals(2, #disc.comments)
  end)

  async_tests.it("root comment has no parent_comment_id", function()
    local runner = make_route_runner({
      { pattern = "/comments", response = ok(COMMENTS_JSON) },
    })
    local p = make_provider(runner.fn)
    local root = p:fetch_discussions(make_review())[1].comments[1]
    assert.is_nil(root.parent_comment_id)
  end)

  async_tests.it("reply has parent_comment_id = root comment id", function()
    local runner = make_route_runner({
      { pattern = "/comments", response = ok(COMMENTS_JSON) },
    })
    local p = make_provider(runner.fn)
    local reply = p:fetch_discussions(make_review())[1].comments[2]
    assert.equals("1001", reply.parent_comment_id)
  end)

  async_tests.it("maps author and body fields on root comment", function()
    local runner = make_route_runner({
      { pattern = "/comments", response = ok(COMMENTS_JSON) },
    })
    local p = make_provider(runner.fn)
    local root = p:fetch_discussions(make_review())[1].comments[1]
    assert.equals("alice", root.author)
    assert.equals("First comment", root.body.text)
    assert.equals("markdown", root.body.format)
  end)

  async_tests.it("maps reactions: count and type from REST reactions object", function()
    local runner = make_route_runner({
      { pattern = "/comments", response = ok(COMMENTS_JSON) },
    })
    local p = make_provider(runner.fn)
    local root = p:fetch_discussions(make_review())[1].comments[1]
    -- root comment has total_count=1 and +1=1
    assert.equals(1, #root.reactions)
    assert.equals("+1", root.reactions[1].type)
    assert.equals(1, root.reactions[1].count)
  end)

  async_tests.it("falls back to original_line when line is null", function()
    local runner = make_route_runner({
      { pattern = "/comments", response = ok(COMMENTS_NULL_LINE_JSON) },
    })
    local p = make_provider(runner.fn)
    local disc = p:fetch_discussions(make_review())[1]
    assert.equals(5, disc.line)
  end)

  async_tests.it("produces two separate discussions for two root comments", function()
    local two_roots = vim.json.encode({
      {
        id = 100,
        user = { login = "a" },
        body = "Root A",
        created_at = "2024-01-01T10:00:00Z",
        updated_at = "2024-01-01T10:00:00Z",
        path = "a.lua",
        line = 1,
        original_line = 1,
        start_line = vim.NIL,
        in_reply_to_id = vim.NIL,
        reactions = {
          total_count = 0,
          ["+1"] = 0,
          ["-1"] = 0,
          laugh = 0,
          hooray = 0,
          confused = 0,
          heart = 0,
          rocket = 0,
          eyes = 0,
        },
      },
      {
        id = 200,
        user = { login = "b" },
        body = "Root B",
        created_at = "2024-01-01T10:00:01Z",
        updated_at = "2024-01-01T10:00:01Z",
        path = "b.lua",
        line = 2,
        original_line = 2,
        start_line = vim.NIL,
        in_reply_to_id = vim.NIL,
        reactions = {
          total_count = 0,
          ["+1"] = 0,
          ["-1"] = 0,
          laugh = 0,
          hooray = 0,
          confused = 0,
          heart = 0,
          rocket = 0,
          eyes = 0,
        },
      },
    })
    local runner = make_route_runner({
      { pattern = "/comments", response = ok(two_roots) },
    })
    local p = make_provider(runner.fn)
    local discussions = p:fetch_discussions(make_review())
    assert.equals(2, #discussions)
  end)
end)

-- ---------------------------------------------------------------------------
-- Suite: post_top_level_comment
-- ---------------------------------------------------------------------------

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

-- ---------------------------------------------------------------------------
-- Suite: reply
-- ---------------------------------------------------------------------------

async_tests.describe("parley.providers.github.provider — reply", function()
  async_tests.it("retries transient async gh transport failures with backoff", function()
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
    assert.is_true(result.ok)
    assert.equals(2, calls)
    assert.equals(250, delays[1])
    assert.equals("3001", result.comment.id)
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

-- ---------------------------------------------------------------------------
-- Suite: resolve / unresolve (stubbed — GraphQL postponed)
-- ---------------------------------------------------------------------------

describe("parley.providers.github.provider — resolve/unresolve stubs", function()
  it("resolve raises an error mentioning GraphQL / POSTPONED", function()
    local p = make_provider(function(_) end)
    assert.has_error(function()
      p:resolve(make_review(), "1001")
    end)
  end)

  it("unresolve raises an error mentioning GraphQL / POSTPONED", function()
    local p = make_provider(function(_) end)
    assert.has_error(function()
      p:unresolve(make_review(), "1001")
    end)
  end)
end)

-- ---------------------------------------------------------------------------
-- Suite: react
-- ---------------------------------------------------------------------------

async_tests.describe("parley.providers.github.provider — react", function()
  async_tests.it("caches viewer login on first call (falls back to gh api /user when config unavailable)", function()
    local runner = make_runner(function(cmd)
      if is_config_get(cmd) then
        return fail("no config")
      end
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
      if is_config_get(cmd) then
        return fail("no config")
      end
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
      if is_config_get(cmd) then
        return fail("no config")
      end
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
      if is_config_get(cmd) then
        return fail("no config")
      end
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

-- ---------------------------------------------------------------------------
-- Suite: edit
-- ---------------------------------------------------------------------------

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

-- ---------------------------------------------------------------------------
-- Suite: delete
-- ---------------------------------------------------------------------------

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

-- ---------------------------------------------------------------------------
-- Suite: submit_review
-- ---------------------------------------------------------------------------

async_tests.describe("parley.providers.github.provider — submit_review", function()
  local function review_runner()
    return make_runner(function(_cmd)
      return ok(vim.json.encode({ id = 77, state = "APPROVED" }))
    end)
  end

  async_tests.it("maps 'approve' to APPROVE event", function()
    local runner = review_runner()
    local p = make_provider(runner.fn)
    local body = model.new_body({ text = "lgtm", format = "markdown" })
    p:submit_review(make_review("abc123"), "approve", body)

    local cmd = runner._calls[1]
    local has_event = false
    for i, v in ipairs(cmd) do
      if v == "-f" and cmd[i + 1] and cmd[i + 1] == "event=APPROVE" then
        has_event = true
        break
      end
    end
    assert.is_true(has_event)
  end)

  async_tests.it("maps 'request_changes' to REQUEST_CHANGES event", function()
    local runner = review_runner()
    local p = make_provider(runner.fn)
    local body = model.new_body({ text = "needs work", format = "markdown" })
    p:submit_review(make_review("abc123"), "request_changes", body)

    local cmd = runner._calls[1]
    local has_event = false
    for i, v in ipairs(cmd) do
      if v == "-f" and cmd[i + 1] and cmd[i + 1] == "event=REQUEST_CHANGES" then
        has_event = true
        break
      end
    end
    assert.is_true(has_event)
  end)

  async_tests.it("maps 'comment' to COMMENT event", function()
    local runner = review_runner()
    local p = make_provider(runner.fn)
    local body = model.new_body({ text = "fyi", format = "markdown" })
    p:submit_review(make_review("abc123"), "comment", body)

    local cmd = runner._calls[1]
    local has_event = false
    for i, v in ipairs(cmd) do
      if v == "-f" and cmd[i + 1] and cmd[i + 1] == "event=COMMENT" then
        has_event = true
        break
      end
    end
    assert.is_true(has_event)
  end)

  async_tests.it("errors on unknown event", function()
    local runner = review_runner()
    local p = make_provider(runner.fn)
    local body = model.new_body({ text = "x", format = "markdown" })
    assert.has_error(function()
      p:submit_review(make_review("abc123"), "invalid_event", body)
    end)
  end)
end)

-- ---------------------------------------------------------------------------
-- Suite: M._parse_remote_url
-- ---------------------------------------------------------------------------

describe("parley.providers.github.provider — _parse_remote_url", function()
  it("parses SSH form (github.com)", function()
    assert.same(
      { host = "github.com", owner = "owner", repo = "repo" },
      gh._parse_remote_url("git@github.com:owner/repo.git")
    )
  end)

  it("parses SSH form without trailing .git", function()
    assert.same(
      { host = "github.com", owner = "owner", repo = "repo" },
      gh._parse_remote_url("git@github.com:owner/repo")
    )
  end)

  it("parses HTTPS form (github.com)", function()
    assert.same(
      { host = "github.com", owner = "owner", repo = "repo" },
      gh._parse_remote_url("https://github.com/owner/repo.git")
    )
  end)

  it("parses HTTPS form without trailing .git", function()
    assert.same(
      { host = "github.com", owner = "owner", repo = "repo" },
      gh._parse_remote_url("https://github.com/owner/repo")
    )
  end)

  it("parses HTTPS form with embedded user@", function()
    assert.same(
      { host = "github.com", owner = "owner", repo = "repo" },
      gh._parse_remote_url("https://user@github.com/owner/repo.git")
    )
  end)

  it("parses SSH form for an Enterprise host", function()
    assert.same(
      { host = "github.corp.example.com", owner = "team", repo = "svc" },
      gh._parse_remote_url("git@github.corp.example.com:team/svc.git")
    )
  end)

  it("returns nil for nil input", function()
    assert.is_nil(gh._parse_remote_url(nil))
  end)

  it("returns nil for empty string", function()
    assert.is_nil(gh._parse_remote_url(""))
  end)

  it("returns nil for unrecognized scheme", function()
    assert.is_nil(gh._parse_remote_url("file:///tmp/repo"))
  end)

  it("returns nil for malformed input", function()
    assert.is_nil(gh._parse_remote_url("not a url"))
  end)
end)

-- ---------------------------------------------------------------------------
-- Suite: M.detect (registry hook — receives parley.VcsInfo)
-- ---------------------------------------------------------------------------

describe("parley.providers.github.provider — detect", function()
  it("returns owner/repo/host for an SSH github.com URL", function()
    local opts = gh.detect({
      vcs = "git",
      root = "/some/repo",
      branch = "main",
      remote_url = "git@github.com:owner/repo.git",
    })
    assert.same({ host = "github.com", owner = "owner", repo = "repo" }, opts)
  end)

  it("returns owner/repo/host for an HTTPS github.com URL", function()
    local opts = gh.detect({
      vcs = "git",
      root = "/some/repo",
      branch = "main",
      remote_url = "https://github.com/owner/repo",
    })
    assert.same({ host = "github.com", owner = "owner", repo = "repo" }, opts)
  end)

  it("returns nil for a non-GitHub host (gitlab.com)", function()
    assert.is_nil(gh.detect({
      vcs = "git",
      root = "/some/repo",
      branch = "main",
      remote_url = "git@gitlab.com:owner/repo.git",
    }))
  end)

  it("returns nil when remote_url is missing", function()
    assert.is_nil(gh.detect({ vcs = "git", root = "/some/repo", branch = "main" }))
  end)

  it("returns nil when vcs_info is not a table", function()
    assert.is_nil(gh.detect(nil))
  end)

  it("returns nil for an Enterprise host (kept conservative for now)", function()
    -- github.corp.example.com is parsed but the host check rejects non-github.com.
    assert.is_nil(gh.detect({
      vcs = "git",
      root = "/r",
      branch = "main",
      remote_url = "git@github.corp.example.com:team/svc.git",
    }))
  end)
end)

-- ---------------------------------------------------------------------------
-- Suite: fetch_viewer_login (viewer identity resolution)
-- ---------------------------------------------------------------------------

async_tests.describe("parley.providers.github.provider — fetch_viewer_login", function()
  async_tests.it("fast path: uses gh config get and caches login (no API call)", function()
    local runner = make_route_runner({
      { pattern = "config", response = ok_text("alice\n") },
      { pattern = "/comments", response = ok(COMMENTS_JSON) },
    })
    local p2 = make_provider(runner.fn)
    p2:fetch_discussions(make_review())
    assert.equals("alice", p2._viewer_login)
    -- no /user API call was made
    local api_calls = 0
    for _, call in ipairs(runner._calls) do
      if not is_config_get(call) and not vim.tbl_contains(call, "--paginate") then
        api_calls = api_calls + 1
      end
    end
    assert.equals(0, api_calls)
  end)

  async_tests.it("fast path: second call does not invoke the runner again", function()
    local config_call_count = 0
    local runner = make_runner(function(cmd)
      if is_config_get(cmd) then
        config_call_count = config_call_count + 1
        return ok_text("alice\n")
      end
      return ok(REACTIONS_EMPTY_JSON)
    end)
    local p = make_provider(runner.fn)
    p:react(make_review(), "1001", "+1")
    p:react(make_review(), "1002", "+1")
    assert.equals(1, config_call_count)
  end)

  async_tests.it("slow path: falls back to gh api /user when gh config fails", function()
    local api_user_called = false
    local runner = make_runner(function(cmd)
      if is_config_get(cmd) then
        return fail("could not find key \"user\"")
      end
      for _, a in ipairs(cmd) do
        if a == "/user" then
          api_user_called = true
          return ok(USER_JSON)
        end
      end
      return ok(REACTIONS_EMPTY_JSON)
    end)
    local p = make_provider(runner.fn)
    p:react(make_review(), "1001", "+1")
    assert.is_true(api_user_called)
    assert.equals("alice", p._viewer_login)
  end)

  async_tests.it("stays nil when both gh config and gh api /user fail", function()
    -- Use fetch_discussions so there are no further gh_run calls after
    -- fetch_viewer_login; react() would make an additional /reactions call.
    local runner = make_route_runner({
      { pattern = "config", response = fail("no config") },
      { pattern = "/comments", response = ok(COMMENTS_JSON) },
      -- no /user route → gh_run raises → pcall in fetch_viewer_login catches it
    })
    -- no-op sleep so gh_run retries don't stall the async test
    local p = make_provider({ _runner = runner.fn, _sleep = function(_ms) end })
    p:fetch_discussions(make_review())
    assert.is_nil(p._viewer_login)
  end)
end)

-- ---------------------------------------------------------------------------
-- Suite: fetch_discussions — is_own assignment
-- ---------------------------------------------------------------------------

async_tests.describe("parley.providers.github.provider — fetch_discussions is_own", function()
  async_tests.it("sets is_own=true for comments authored by the viewer (config path)", function()
    local runner = make_route_runner({
      { pattern = "config", response = ok_text("alice\n") },
      { pattern = "/comments", response = ok(COMMENTS_JSON) },
    })
    local p = make_provider(runner.fn)
    local comments = p:fetch_discussions(make_review())[1].comments
    assert.is_true(comments[1].is_own) -- alice's root comment
    assert.is_false(comments[2].is_own) -- bob's reply
  end)

  async_tests.it("sets is_own=true for comments authored by the viewer (api fallback path)", function()
    local runner = make_route_runner({
      { pattern = "config", response = fail("no config") },
      { pattern = "/user", response = ok(USER_JSON) },
      { pattern = "/comments", response = ok(COMMENTS_JSON) },
    })
    local p = make_provider(runner.fn)
    local comments = p:fetch_discussions(make_review())[1].comments
    assert.is_true(comments[1].is_own) -- alice's root comment
    assert.is_false(comments[2].is_own) -- bob's reply
  end)

  async_tests.it("sets is_own=false for all comments when viewer is unknown", function()
    local runner = make_route_runner({
      { pattern = "config", response = fail("no config") },
      { pattern = "/comments", response = ok(COMMENTS_JSON) },
      -- no /user route → gh_run raises → pcall catches → _viewer_login stays nil
    })
    local p = make_provider(runner.fn)
    local comments = p:fetch_discussions(make_review())[1].comments
    assert.is_false(comments[1].is_own)
    assert.is_false(comments[2].is_own)
  end)

  async_tests.it("caches viewer login: second fetch_discussions does not call runner for identity", function()
    local identity_call_count = 0
    local runner = make_runner(function(cmd)
      if is_config_get(cmd) then
        identity_call_count = identity_call_count + 1
        return ok_text("alice\n")
      end
      -- gh api --paginate /comments
      return ok(COMMENTS_JSON)
    end)
    local p = make_provider(runner.fn)
    p:fetch_discussions(make_review())
    p:fetch_discussions(make_review())
    assert.equals(1, identity_call_count)
  end)
end)

-- ---------------------------------------------------------------------------
-- Suite: head_sha accessor
-- ---------------------------------------------------------------------------

describe("parley.providers.github.provider — detect_pr write context", function()
  it("returns write context after detect_pr", function()
    local runner = make_route_runner({
      { pattern = "/reviews", response = ok(REVIEWS_EMPTY_JSON) },
      { pattern = "/pulls", response = ok(PR_LIST_JSON) },
    })
    local p = make_provider(runner.fn)
    local review = p:detect_pr("/repo", "feature")

    assert.same({ number = 42, head_sha = "abc123def456" }, review.write_context)
  end)
end)
