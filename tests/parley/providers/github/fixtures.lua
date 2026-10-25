--- Tests for parley.providers.github.provider — GitHub provider implementation.
--- Run via: make test

local model = require("parley.model")
local gh = require("parley.providers.github.provider")
local transport = require("parley.providers.github.transport")

-- All tests in this file inject a fake _runner/_spawn and exercise provider
-- logic, not the gh availability guard. Mark gh as available so that
-- check_gh_available() does not re-probe (which would fail in CI where gh is
-- absent) and lets the injected runners receive the call.
transport._gh_available = true

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

--- GraphQL reviewThreads response: one thread, resolved, rooted at comment 1001.
local REVIEW_THREADS_RESOLVED_JSON = vim.json.encode({
  data = {
    repository = {
      pullRequest = {
        reviewThreads = {
          pageInfo = { hasNextPage = false, endCursor = vim.NIL },
          nodes = {
            {
              id = "RT_1001",
              isResolved = true,
              comments = { nodes = { { databaseId = 1001 } } },
            },
          },
        },
      },
    },
  },
})

--- GraphQL reviewThreads response: one thread, unresolved, rooted at comment 1001.
local REVIEW_THREADS_UNRESOLVED_JSON = vim.json.encode({
  data = {
    repository = {
      pullRequest = {
        reviewThreads = {
          pageInfo = { hasNextPage = false, endCursor = vim.NIL },
          nodes = {
            {
              id = "RT_1001",
              isResolved = false,
              comments = { nodes = { { databaseId = 1001 } } },
            },
          },
        },
      },
    },
  },
})

--- GraphQL mutation response for resolveReviewThread/unresolveReviewThread.
local RESOLVE_MUTATION_RESP_JSON = vim.json.encode({
  data = { resolveReviewThread = { thread = { id = "RT_1001", isResolved = true } } },
})
local UNRESOLVE_MUTATION_RESP_JSON = vim.json.encode({
  data = { unresolveReviewThread = { thread = { id = "RT_1001", isResolved = false } } },
})

--- GraphQL error response (HTTP 200, top-level `errors` array).
local GRAPHQL_ERROR_JSON = vim.json.encode({
  errors = { { message = "Could not resolve to a node with the global id of 'bogus'" } },
})

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
    local result = vim.deepcopy(dispatch(cmd))
    if result.code == 0 and vim.tbl_contains(cmd, "--slurp") then
      result.stdout = "[" .. result.stdout .. "]"
    end
    return result
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
---   config?: table,
---   _system?: fun(cmd: string[], opts: table, callback: fun(result: vim.SystemCompleted)): vim.SystemObj,
--- }
local function make_provider(opts)
  if type(opts) == "function" then
    opts = { _runner = opts }
  end
  opts = opts or {}
  return gh.new({
    repository = "owner/repo",
    _runner = opts._runner,
    _spawn = opts._spawn,
    _sleep = opts._sleep,
    _defer = opts._defer,
    config = opts.config,
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

return {
  model = model,
  gh = gh,
  PR_LIST_JSON = PR_LIST_JSON,
  PR_LIST_EMPTY_JSON = PR_LIST_EMPTY_JSON,
  REVIEWS_APPROVED_JSON = REVIEWS_APPROVED_JSON,
  REVIEWS_CHANGES_JSON = REVIEWS_CHANGES_JSON,
  REVIEWS_EMPTY_JSON = REVIEWS_EMPTY_JSON,
  COMMENTS_JSON = COMMENTS_JSON,
  COMMENTS_NULL_LINE_JSON = COMMENTS_NULL_LINE_JSON,
  POST_COMMENT_RESP_JSON = POST_COMMENT_RESP_JSON,
  USER_JSON = USER_JSON,
  REACTIONS_WITH_VIEWER_JSON = REACTIONS_WITH_VIEWER_JSON,
  REACTIONS_WITHOUT_VIEWER_JSON = REACTIONS_WITHOUT_VIEWER_JSON,
  REACTIONS_EMPTY_JSON = REACTIONS_EMPTY_JSON,
  EDIT_COMMENT_RESP_JSON = EDIT_COMMENT_RESP_JSON,
  REACTION_CREATED_JSON = REACTION_CREATED_JSON,
  REVIEW_THREADS_RESOLVED_JSON = REVIEW_THREADS_RESOLVED_JSON,
  REVIEW_THREADS_UNRESOLVED_JSON = REVIEW_THREADS_UNRESOLVED_JSON,
  RESOLVE_MUTATION_RESP_JSON = RESOLVE_MUTATION_RESP_JSON,
  UNRESOLVE_MUTATION_RESP_JSON = UNRESOLVE_MUTATION_RESP_JSON,
  GRAPHQL_ERROR_JSON = GRAPHQL_ERROR_JSON,
  make_runner = make_runner,
  ok = ok,
  ok_text = ok_text,
  ok_empty = ok_empty,
  fail = fail,
  is_config_get = is_config_get,
  make_route_runner = make_route_runner,
  make_auth = make_auth,
  make_auth_err = make_auth_err,
  make_provider = make_provider,
  SAMPLE_PR = SAMPLE_PR,
  make_review = make_review,
  make_anchor = make_anchor,
}
