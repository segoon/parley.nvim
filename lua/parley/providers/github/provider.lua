--- parley.providers.github.provider — GitHub provider implementation.
---
--- Implements parley.Provider against the GitHub REST API via the `gh` CLI.
--- All network calls are made by shelling out to `gh api …`, which handles
--- authentication (env vars, hosts.yml, keyring, SSO) and rate-limiting
--- transparently.
---
--- Design notes:
---   • Transport: `gh api` subprocess via vim.system + plenary.async.
---   • Discussion IDs = root review-comment database ID (string).
---     This lets reply() pass it directly as `in_reply_to`.
---   • resolved = false always — GraphQL required for resolved state.
---     See POSTPONED.md.
---   • resolve / unresolve are stubs that raise an error.
---
--- Testability:
---   • _runner: fun(cmd: string[]): {code,stdout,stderr}  — replace in tests.
---   • _auth:   auth module table with read_token(host)    — replace in tests.
---   • _io_open: io.open replacement for detect()         — replace in tests.

local async = require("plenary.async")
local model = require("parley.model")

local M = {}

-- ---------------------------------------------------------------------------
-- Type annotations
-- ---------------------------------------------------------------------------

--- @class parley.github.PrCache
--- @field head_sha string
--- @field number   integer

--- @class parley.github.Provider : parley.Provider
--- @field _host         string
--- @field _owner        string
--- @field _repo         string
--- @field _api_base     string
--- @field _runner       fun(cmd: string[]): {code: integer, stdout: string, stderr: string}
--- @field _auth         table
--- @field _pr_cache     table<string, parley.github.PrCache>
--- @field _viewer_login string|nil

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

--- Map REST reactions object keys → internal reaction type strings.
--- The REST API response embeds counts under the emoji-name keys directly.
--- @type string[]
local REST_REACTION_KEYS = { "+1", "-1", "laugh", "hooray", "confused", "heart", "rocket", "eyes" }

--- Map provider event names → GitHub review event values.
--- @type table<string, string>
local REVIEW_EVENT_MAP = {
  approve = "APPROVE",
  request_changes = "REQUEST_CHANGES",
  comment = "COMMENT",
}

--- Map GitHub review states → parley.ReviewStatus values.
--- @type table<string, string>
local GH_REVIEW_STATE_MAP = {
  APPROVED = "approved",
  CHANGES_REQUESTED = "changes_requested",
  DISMISSED = "dismissed",
  COMMENTED = "commented",
}

-- ---------------------------------------------------------------------------
-- Injectable seams
-- ---------------------------------------------------------------------------

--- Override io.open in detect() for tests.
--- @type fun(path: string, mode: string): table|nil
M._io_open = nil

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Return the active io.open implementation.
--- @return fun(path: string, mode: string): table|nil
local function io_open(path, mode)
  if M._io_open then
    return M._io_open(path, mode)
  end
  return io.open(path, mode)
end

--- Build the REST API base URL for a given GitHub host.
--- @param host string  e.g. "github.com" or "ghe.corp.com"
--- @return string
local function api_base_for_host(host)
  if host == "github.com" then
    return "https://api.github.com"
  end
  return "https://" .. host .. "/api/v3"
end

--- Compute review_status from a list of GitHub review objects.
--- Takes the last non-PENDING entry (reviews are in chronological order).
--- @param reviews table[]
--- @return parley.ReviewStatus
local function compute_review_status(reviews)
  local status = "pending"
  for _, r in ipairs(reviews) do
    local mapped = GH_REVIEW_STATE_MAP[r.state]
    if mapped then
      status = mapped
    end
  end
  return status
end

--- Map the REST reactions object (embedded in a comment) to parley.Reaction[].
--- The REST API embeds counts as `{"+1": N, "-1": N, ...}` under `reactions`.
--- Only includes reaction types with count > 0.
--- @param raw table  the `reactions` sub-object from a REST review comment
--- @return parley.Reaction[]
local function map_rest_reactions(raw)
  if not raw then
    return {}
  end
  local result = {}
  for _, key in ipairs(REST_REACTION_KEYS) do
    local count = raw[key]
    if type(count) == "number" and count > 0 then
      table.insert(
        result,
        model.new_reaction({
          type = key,
          count = count,
          -- REST comment reactions do not expose per-viewer state;
          -- viewer_reacted is determined lazily in react() via a separate call.
          viewer_reacted = false,
        })
      )
    end
  end
  return result
end

--- Map a single raw REST review comment to a parley.Comment.
--- @param raw    table   Raw GitHub review comment object
--- @param viewer string  Authenticated viewer's login (for is_own)
--- @return parley.Comment
local function map_rest_comment(raw, viewer)
  local parent_id = nil
  if raw.in_reply_to_id and raw.in_reply_to_id ~= vim.NIL then
    parent_id = tostring(raw.in_reply_to_id)
  end
  return model.new_comment({
    id = tostring(raw.id),
    author = raw.user and raw.user.login or "",
    body = model.new_body({ text = raw.body or "", format = "markdown" }),
    created_at = raw.created_at or "",
    updated_at = raw.updated_at or "",
    reactions = map_rest_reactions(raw.reactions),
    is_own = (raw.user and raw.user.login == viewer) or false,
    parent_comment_id = parent_id,
  })
end

--- Group a flat list of REST review comments into parley.Discussion[].
---
--- Grouping rules:
---   • A comment with no in_reply_to_id is a root → new Discussion.
---   • A comment with in_reply_to_id belongs to the Discussion whose id equals
---     that value (GitHub always points replies at the root, not a direct parent).
---
--- @param comments table[]  Raw GitHub review comment objects (ordered by created_at)
--- @param viewer   string   Authenticated viewer's login
--- @return parley.Discussion[]
local function group_comments_into_discussions(comments, viewer)
  --- @type table<string, parley.Discussion>
  local by_root = {}
  --- @type string[]  Insertion-order list of root ids (for stable output order)
  local order = {}

  for _, raw in ipairs(comments) do
    local is_root = not raw.in_reply_to_id or raw.in_reply_to_id == vim.NIL
    local comment = map_rest_comment(raw, viewer)

    if is_root then
      local root_id = tostring(raw.id)
      local line = raw.line
      if not line or line == vim.NIL then
        line = raw.original_line or 0
      end
      local disc = model.new_discussion({
        id = root_id,
        file = raw.path or "",
        line = line,
        end_line = (raw.start_line and raw.start_line ~= vim.NIL) and raw.line or nil,
        resolved = false, -- GraphQL required; see POSTPONED.md
        comments = { comment },
      })
      by_root[root_id] = disc
      table.insert(order, root_id)
    else
      local root_id = tostring(raw.in_reply_to_id)
      local disc = by_root[root_id]
      if disc then
        table.insert(disc.comments, comment)
      end
      -- If root not seen yet (shouldn't happen with GitHub's ordering), skip.
    end
  end

  local result = {}
  for _, root_id in ipairs(order) do
    table.insert(result, by_root[root_id])
  end
  return result
end

-- ---------------------------------------------------------------------------
-- Provider object
-- ---------------------------------------------------------------------------

--- @type parley.github.Provider
local GitHubProvider = {}
GitHubProvider.__index = GitHubProvider

--- Run a gh CLI command and return parsed JSON.
--- Raises on non-zero exit or JSON parse failure.
--- Returns nil (not an error) when stdout is empty (e.g. DELETE 204).
---
--- @param self  parley.github.Provider
--- @param cmd   string[]
--- @return table|nil
local function gh_run(self, cmd)
  local runner = self._runner
  local result = runner(cmd)
  if result.code ~= 0 then
    error(string.format("parley.github: gh command failed (exit %d): %s", result.code, result.stderr or ""), 0)
  end
  local stdout = result.stdout or ""
  if stdout == "" then
    return nil
  end
  local ok_decode, decoded = pcall(vim.json.decode, stdout)
  if not ok_decode then
    error(string.format("parley.github: failed to decode JSON response: %s", stdout), 0)
  end
  return decoded
end

--- Build the base REST path prefix for this repo.
--- @param self parley.github.Provider
--- @return string  e.g. "/repos/owner/repo"
local function repo_path(self)
  return "/repos/" .. self._owner .. "/" .. self._repo
end

-- ---------------------------------------------------------------------------
-- Constructor
-- ---------------------------------------------------------------------------

--- Create a new GitHub provider.
---
--- Required opts: owner, repo.
--- Optional opts: host (default "github.com"), api_base, _runner, _auth.
---
--- @param opts { owner: string, repo: string, host?: string, api_base?: string,
---   _runner?: fun(cmd: string[]): table, _auth?: table }
--- @return parley.github.Provider
function M.new(opts)
  opts = opts or {}
  assert(type(opts.owner) == "string" and opts.owner ~= "", "parley.github: opts.owner must be a non-empty string")
  assert(type(opts.repo) == "string" and opts.repo ~= "", "parley.github: opts.repo must be a non-empty string")

  local host = opts.host or "github.com"

  local default_runner = async.wrap(function(cmd, callback)
    vim.system(cmd, { text = true }, function(result)
      callback({ code = result.code, stdout = result.stdout or "", stderr = result.stderr or "" })
    end)
  end, 2)

  local self = setmetatable({
    _host = host,
    _owner = opts.owner,
    _repo = opts.repo,
    _api_base = opts.api_base or api_base_for_host(host),
    _runner = opts._runner or default_runner,
    _auth = opts._auth or require("parley.providers.github.auth"),
    _pr_cache = {},
    _viewer_login = nil,
  }, GitHubProvider)

  return self
end

-- ---------------------------------------------------------------------------
-- parley.Provider interface
-- ---------------------------------------------------------------------------

--- Return the authentication token for this host.
--- @param self parley.github.Provider
--- @return string
function GitHubProvider:auth()
  local token, err = self._auth.read_token(self._host)
  if not token then
    error(string.format("parley.github: auth failed: %s", err or "unknown error"), 0)
  end
  return token
end

--- Detect an open PR for the given branch.
--- Makes two REST calls: PR list + reviews.
--- Caches head_sha and PR number in self._pr_cache[pr.id].
---
--- @param self       parley.github.Provider
--- @param _repo_root string  (unused — owner/repo already known from constructor)
--- @param branch     string
--- @return parley.PR|nil
function GitHubProvider:detect_pr(_repo_root, branch)
  local pulls_url = repo_path(self) .. "/pulls?head=" .. self._owner .. ":" .. branch .. "&state=open&per_page=1"

  local pulls = gh_run(self, { "gh", "api", pulls_url })
  if not pulls or #pulls == 0 then
    return nil
  end

  local raw = pulls[1]
  local pr_number = raw.number

  -- Fetch reviews to determine review_status.
  local reviews_url = repo_path(self) .. "/pulls/" .. pr_number .. "/reviews"
  local reviews = gh_run(self, { "gh", "api", reviews_url }) or {}

  local review_status = compute_review_status(reviews)

  local pr = model.new_pr({
    id = tostring(pr_number),
    title = raw.title or "",
    state = raw.state or "open",
    base_branch = raw.base and raw.base.ref or "",
    head_branch = raw.head and raw.head.ref or "",
    author = raw.user and raw.user.login or "",
    url = raw.html_url or "",
    review_status = review_status,
  })

  -- Cache for methods that need commit SHA or PR number.
  self._pr_cache[pr.id] = {
    head_sha = raw.head and raw.head.sha or "",
    number = pr_number,
  }

  return pr
end

--- Fetch all discussions for a PR using the REST review-comments endpoint.
--- Discussions are grouped by root comment id.
--- resolved is always false (GraphQL required — see POSTPONED.md).
---
--- @param self parley.github.Provider
--- @param pr   parley.PR
--- @return parley.Discussion[]
function GitHubProvider:fetch_discussions(pr)
  local cached = self._pr_cache[pr.id]
  local pr_number = cached and cached.number or tonumber(pr.id)
  local url = repo_path(self) .. "/pulls/" .. pr_number .. "/comments"

  local comments = gh_run(self, { "gh", "api", "--paginate", url }) or {}

  -- Use auth username as viewer for is_own detection.
  -- Ignore errors — is_own defaults to false.
  local viewer = ""
  local ok_auth, token = pcall(function()
    return self:auth()
  end)
  if ok_auth and token then
    -- Best-effort: viewer login is derived lazily in react(); here we leave
    -- is_own = false unless we already have it cached.
    viewer = self._viewer_login or ""
  end

  return group_comments_into_discussions(comments, viewer)
end

--- Post a new top-level review comment anchored to a file/line.
---
--- @param self parley.github.Provider
--- @param pr   parley.PR
--- @param file string
--- @param line integer
--- @param body parley.Body
--- @return parley.Comment
function GitHubProvider:post_comment(pr, file, line, body)
  local cached = self._pr_cache[pr.id]
  assert(cached, "parley.github: detect_pr must be called before post_comment (pr not in cache)")

  local url = repo_path(self) .. "/pulls/" .. cached.number .. "/comments"
  local raw = gh_run(self, {
    "gh",
    "api",
    "--method",
    "POST",
    url,
    "-f",
    "body=" .. body.text,
    "-f",
    "commit_id=" .. cached.head_sha,
    "-f",
    "path=" .. file,
    "-F",
    "line=" .. tostring(line),
    "-f",
    "subject_type=line",
  })

  return map_rest_comment(raw, self._viewer_login or "")
end

--- Post a reply to an existing discussion.
--- discussion_id is the root comment's database id (used as in_reply_to).
---
--- @param self          parley.github.Provider
--- @param pr            parley.PR
--- @param discussion_id string  Root comment database id
--- @param body          parley.Body
--- @return parley.Comment
function GitHubProvider:reply(pr, discussion_id, body)
  local cached = self._pr_cache[pr.id]
  assert(cached, "parley.github: detect_pr must be called before reply (pr not in cache)")

  local url = repo_path(self) .. "/pulls/" .. cached.number .. "/comments"
  local raw = gh_run(self, {
    "gh",
    "api",
    "--method",
    "POST",
    url,
    "-f",
    "body=" .. body.text,
    "-f",
    "commit_id=" .. cached.head_sha,
    "-F",
    "in_reply_to=" .. discussion_id,
  })

  return map_rest_comment(raw, self._viewer_login or "")
end

--- Resolve a discussion thread.
--- NOT IMPLEMENTED — requires GraphQL. See POSTPONED.md.
---
--- @param self          parley.github.Provider
--- @param _pr           parley.PR
--- @param _discussion_id string
function GitHubProvider:resolve(_pr, _discussion_id)
  local _ = self
  error("parley.github: resolve requires GraphQL (see POSTPONED.md)", 0)
end

--- Unresolve a discussion thread.
--- NOT IMPLEMENTED — requires GraphQL. See POSTPONED.md.
---
--- @param self          parley.github.Provider
--- @param _pr           parley.PR
--- @param _discussion_id string
function GitHubProvider:unresolve(_pr, _discussion_id)
  local _ = self
  error("parley.github: unresolve requires GraphQL (see POSTPONED.md)", 0)
end

--- Toggle a reaction on a comment (add if absent, remove if present).
---
--- Steps:
---   1. Ensure viewer login is cached (GET /user once).
---   2. GET /reactions?content=<type> for the comment.
---   3. If viewer has a reaction → DELETE it; otherwise → POST a new one.
---
--- @param self       parley.github.Provider
--- @param _pr        parley.PR
--- @param comment_id string
--- @param reaction   string  e.g. "+1", "heart"
function GitHubProvider:react(_pr, comment_id, reaction)
  -- Ensure viewer login is cached.
  if not self._viewer_login then
    local user = gh_run(self, { "gh", "api", "/user" })
    if user and user.login then
      self._viewer_login = user.login
    end
  end

  local viewer = self._viewer_login or ""
  local base_url = repo_path(self) .. "/pulls/comments/" .. comment_id .. "/reactions"

  -- Fetch existing reactions of this type.
  local reactions = gh_run(self, {
    "gh",
    "api",
    base_url .. "?content=" .. reaction .. "&per_page=100",
  }) or {}

  -- Check whether viewer has already reacted.
  local existing_id = nil
  for _, r in ipairs(reactions) do
    if r.user and r.user.login == viewer then
      existing_id = r.id
      break
    end
  end

  if existing_id then
    -- Remove reaction.
    gh_run(self, {
      "gh",
      "api",
      "--method",
      "DELETE",
      base_url .. "/" .. tostring(existing_id),
    })
  else
    -- Add reaction.
    gh_run(self, {
      "gh",
      "api",
      "--method",
      "POST",
      base_url,
      "-f",
      "content=" .. reaction,
    })
  end
end

--- Edit an existing comment body.
---
--- @param self       parley.github.Provider
--- @param _pr        parley.PR
--- @param comment_id string
--- @param body       parley.Body
--- @return parley.Comment
function GitHubProvider:edit(_pr, comment_id, body)
  local url = repo_path(self) .. "/pulls/comments/" .. comment_id
  local raw = gh_run(self, {
    "gh",
    "api",
    "--method",
    "PATCH",
    url,
    "-f",
    "body=" .. body.text,
  })
  return map_rest_comment(raw, self._viewer_login or "")
end

--- Delete a comment.
---
--- @param self       parley.github.Provider
--- @param _pr        parley.PR
--- @param comment_id string
function GitHubProvider:delete(_pr, comment_id)
  local url = repo_path(self) .. "/pulls/comments/" .. comment_id
  gh_run(self, { "gh", "api", "--method", "DELETE", url })
end

--- Submit a PR-level review.
--- event must be one of: "approve", "request_changes", "comment".
---
--- @param self  parley.github.Provider
--- @param pr    parley.PR
--- @param event string
--- @param body  parley.Body
function GitHubProvider:submit_review(pr, event, body)
  local gh_event = REVIEW_EVENT_MAP[event]
  assert(gh_event, string.format("parley.github: unknown review event: %q", event))

  local cached = self._pr_cache[pr.id]
  assert(cached, "parley.github: detect_pr must be called before submit_review (pr not in cache)")

  local url = repo_path(self) .. "/pulls/" .. cached.number .. "/reviews"
  gh_run(self, {
    "gh",
    "api",
    "--method",
    "POST",
    url,
    "-f",
    "body=" .. body.text,
    "-f",
    "event=" .. gh_event,
  })
end

-- ---------------------------------------------------------------------------
-- Registry helpers
-- ---------------------------------------------------------------------------

--- Detect whether a repository path is a GitHub repository.
--- Reads .git/config synchronously; returns true if github.com appears.
---
--- @param path string  Repository root path
--- @return boolean
function M.detect(path)
  local f = io_open(path .. "/.git/config", "r")
  if not f then
    return false
  end
  local content = f:read("*a")
  f:close()
  return content:find("github%.com") ~= nil
end

return M
