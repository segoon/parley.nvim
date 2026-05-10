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
---   • _parse_remote_url is a pure function exported for unit testing.

local await = require("parley.runtime.await")
local dbg = require("parley.debug")
local mapping = require("parley.providers.github.mapping")
local transport = require("parley.providers.github.transport")

local M = {}

-- ---------------------------------------------------------------------------
-- Type annotations
-- ---------------------------------------------------------------------------

--- @class parley.github.WriteContext
--- @field head_sha string
--- @field number   integer

--- @class parley.github.Provider : parley.Provider
--- @field _host         string
--- @field _owner        string
--- @field _repo         string
--- @field _api_base     string
--- @field _runner       fun(cmd: string[]): {code: integer, stdout: string, stderr: string}
--- @field _spawn        fun(
---   cmd: string[],
---   callback: fun(result: {code: integer, stdout: string, stderr: string})
--- ): vim.SystemObj|nil
--- @field _sleep        fun(timeout_ms: integer): nil
--- @field _defer        fun(callback: fun(), timeout_ms: integer): uv_timer_t|nil
--- @field _get_config   fun(): parley.Config|nil
--- @field _auth         table
--- @field _viewer_login string|nil
--- @field _cache_provider string

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Build the REST API base URL for a given GitHub host.
--- @param host string  e.g. "github.com" or "ghe.corp.com"
--- @return string
local function api_base_for_host(host)
  if host == "github.com" then
    return "https://api.github.com"
  end
  return "https://" .. host .. "/api/v3"
end

--- Build the base REST path prefix for this repo.
--- @param self parley.github.Provider
--- @return string  e.g. "/repos/owner/repo"
local function repo_path(self)
  return "/repos/" .. self._owner .. "/" .. self._repo
end

-- ---------------------------------------------------------------------------
-- Provider object
-- ---------------------------------------------------------------------------

--- @type parley.github.Provider
local GitHubProvider = {}
GitHubProvider.__index = GitHubProvider

-- ---------------------------------------------------------------------------
-- Constructor
-- ---------------------------------------------------------------------------

--- Create a new GitHub provider.
---
--- Required opts: owner, repo.
--- Optional opts: host (default "github.com"), api_base, _runner, _auth.
---
--- @param opts {
---   owner: string,
---   repo: string,
---   host?: string,
---   api_base?: string,
---   _runner?: fun(cmd: string[]): table,
---   _spawn?: fun(
---     cmd: string[],
---     callback: fun(result: {code: integer, stdout: string, stderr: string})
---   ): vim.SystemObj|nil,
---   _sleep?: fun(timeout_ms: integer): nil,
---   _defer?: fun(callback: fun(), timeout_ms: integer): uv_timer_t|nil,
---   _get_config?: fun(): parley.Config|nil,
---   _system?: fun(cmd: string[], opts: table, callback: fun(result: vim.SystemCompleted)): vim.SystemObj,
---   _auth?: table,
--- }
--- @return parley.github.Provider
function M.new(opts)
  opts = opts or {}
  assert(type(opts.owner) == "string" and opts.owner ~= "", "parley.github: opts.owner must be a non-empty string")
  assert(type(opts.repo) == "string" and opts.repo ~= "", "parley.github: opts.repo must be a non-empty string")

  local host = opts.host or "github.com"
  local self
  local system = opts._system or vim.system

  local default_runner = function(cmd)
    local result =
      await.system(cmd, { text = true, timeout = transport.transport_config(self).timeout_ms, _system = system })
    return { code = result.code, stdout = result.stdout or "", stderr = result.stderr or "" }
  end

  local default_spawn = function(cmd, callback)
    local ui = require("parley.runtime.ui")
    return system(
      cmd,
      { text = true, timeout = transport.transport_config(self).timeout_ms },
      ui.wrap(function(result)
        callback({ code = result.code, stdout = result.stdout or "", stderr = result.stderr or "" })
      end)
    )
  end

  self = setmetatable({
    _host = host,
    _owner = opts.owner,
    _repo = opts.repo,
    _api_base = opts.api_base or api_base_for_host(host),
    _runner = opts._runner or default_runner,
    _spawn = opts._spawn or default_spawn,
    _sleep = opts._sleep or await.sleep,
    _defer = opts._defer or vim.defer_fn,
    _get_config = opts._get_config or function()
      return require("parley").config
    end,
    _auth = opts._auth or require("parley.providers.github.auth"),
    _viewer_login = nil,
    _cache_provider = "github",
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
  local read_token = self._auth.read_token_async or self._auth.read_token
  local token, err = read_token(self._host)
  if not token then
    error(string.format("parley.github: auth failed: %s", err or "unknown error"), 0)
  end
  return token
end

--- Detect an open PR for the given branch.
--- Makes two REST calls: PR list + reviews.
---
--- @param self       parley.github.Provider
--- @param _repo_root string  (unused — owner/repo already known from constructor)
--- @param branch     string
--- @return parley.DetectedReview|nil
function GitHubProvider:detect_pr(_repo_root, branch)
  local model = require("parley.model")
  local pulls_url = repo_path(self) .. "/pulls?head=" .. self._owner .. ":" .. branch .. "&state=open&per_page=1"

  local pulls = transport.gh_run(self, { "gh", "api", pulls_url })
  if not pulls or #pulls == 0 then
    return nil
  end

  local raw = pulls[1]
  local pr_number = raw.number

  -- Fetch reviews to determine review_status.
  local reviews_url = repo_path(self) .. "/pulls/" .. pr_number .. "/reviews"
  local reviews = transport.gh_run(self, { "gh", "api", reviews_url }) or {}

  local review_status = mapping.compute_review_status(reviews)

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

  return {
    pr = pr,
    head_sha = raw.head and raw.head.sha or "",
    write_context = {
      head_sha = raw.head and raw.head.sha or "",
      number = pr_number,
    },
  }
end

--- Fetch all discussions for a PR using the REST review-comments endpoint.
--- Discussions are grouped by root comment id.
--- resolved is always false (GraphQL required — see POSTPONED.md).
---
--- @param self parley.github.Provider
--- @param review parley.DetectedReview
--- @return parley.Discussion[]
function GitHubProvider:fetch_discussions(review)
  local pr_number = review.write_context and review.write_context.number or tonumber(review.pr.id)
  local url = repo_path(self) .. "/pulls/" .. pr_number .. "/comments"

  local comments = transport.gh_run(self, { "gh", "api", "--paginate", url }) or {}

  -- Resolve viewer login for is_own detection.
  transport.fetch_viewer_login(self)
  local viewer = self._viewer_login or ""
  dbg.trace(
    "github.provider",
    "fetch_discussions: viewer=" .. vim.inspect(viewer) .. " #comments=" .. tostring(#comments)
  )

  local discussions = mapping.group_comments_into_discussions(comments, viewer)
  local own_count = 0
  for _, d in ipairs(discussions) do
    for _, c in ipairs(d.comments) do
      if c.is_own then
        own_count = own_count + 1
      end
    end
  end
  dbg.trace(
    "github.provider",
    "fetch_discussions: #discussions=" .. tostring(#discussions) .. " is_own_count=" .. tostring(own_count)
  )
  return discussions
end

--- Post a new top-level review comment anchored to a file/line.
---
--- @param self parley.github.Provider
--- @param review parley.DetectedReview
--- @param file string
--- @param anchor parley.Anchor
--- @param body parley.Body
--- @return parley.Comment
function GitHubProvider:post_top_level_comment(review, file, anchor, body)
  local write_context = review.write_context
  dbg.trace(
    "github.provider",
    "post_top_level_comment: pr="
      .. tostring(write_context.number)
      .. " file="
      .. tostring(file)
      .. " anchor="
      .. vim.inspect(anchor)
      .. " head_sha="
      .. tostring(write_context.head_sha)
  )
  local url = repo_path(self) .. "/pulls/" .. write_context.number .. "/comments"
  local cmd = { "gh", "api", "--method", "POST", url }
  vim.list_extend(cmd, mapping.build_top_level_fields(file, anchor, body, write_context))
  local raw = transport.gh_run(self, cmd)

  return mapping.map_rest_comment(raw, self._viewer_login or "")
end

--- Start a cancellable top-level comment request.
--- @param self parley.github.Provider
--- @param review parley.DetectedReview
--- @param file string
--- @param anchor parley.Anchor
--- @param body parley.Body
--- @param callback fun(result: { ok: boolean, comment?: parley.Comment, err?: string, cancelled?: boolean }): nil
--- @return { cancel: fun(): nil }
function GitHubProvider:begin_post_top_level_comment(review, file, anchor, body, callback)
  local write_context = review.write_context
  dbg.trace(
    "github.provider",
    "begin_post_top_level_comment: pr="
      .. tostring(write_context.number)
      .. " file="
      .. tostring(file)
      .. " anchor="
      .. vim.inspect(anchor)
      .. " head_sha="
      .. tostring(write_context.head_sha)
  )
  local url = repo_path(self) .. "/pulls/" .. write_context.number .. "/comments"
  local cmd = { "gh", "api", "--method", "POST", url }
  vim.list_extend(cmd, mapping.build_top_level_fields(file, anchor, body, write_context))
  return transport.gh_start(self, cmd, function(result)
    if not result.ok then
      callback(result)
      return
    end
    callback({ ok = true, comment = mapping.map_rest_comment(result.data, self._viewer_login or "") })
  end)
end

--- Post a reply to an existing discussion.
--- discussion_id is the root comment's database id (used as in_reply_to).
---
--- @param self          parley.github.Provider
--- @param review         parley.DetectedReview
--- @param discussion     parley.Discussion
--- @param parent_comment parley.Comment
--- @param body          parley.Body
--- @return parley.Comment
function GitHubProvider:reply(review, discussion, parent_comment, body)
  local write_context = review.write_context
  local url = repo_path(self) .. "/pulls/" .. write_context.number .. "/comments"
  local _ = discussion
  local raw = transport.gh_run(self, {
    "gh",
    "api",
    "--method",
    "POST",
    url,
    "-f",
    "body=" .. body.text,
    "-f",
    "commit_id=" .. write_context.head_sha,
    "-F",
    "in_reply_to=" .. parent_comment.id,
  })

  return mapping.map_rest_comment(raw, self._viewer_login or "")
end

--- Start a cancellable reply request.
--- @param self parley.github.Provider
--- @param review parley.DetectedReview
--- @param discussion parley.Discussion
--- @param parent_comment parley.Comment
--- @param body parley.Body
--- @param callback fun(result: { ok: boolean, comment?: parley.Comment, err?: string, cancelled?: boolean }): nil
--- @return { cancel: fun(): nil }
function GitHubProvider:begin_reply(review, discussion, parent_comment, body, callback)
  local write_context = review.write_context
  local url = repo_path(self) .. "/pulls/" .. write_context.number .. "/comments"
  local _ = discussion
  return transport.gh_start(self, {
    "gh",
    "api",
    "--method",
    "POST",
    url,
    "-f",
    "body=" .. body.text,
    "-f",
    "commit_id=" .. write_context.head_sha,
    "-F",
    "in_reply_to=" .. parent_comment.id,
  }, function(result)
    if not result.ok then
      callback(result)
      return
    end
    callback({ ok = true, comment = mapping.map_rest_comment(result.data, self._viewer_login or "") })
  end)
end

--- Resolve a discussion thread.
--- NOT IMPLEMENTED — requires GraphQL. See POSTPONED.md.
---
--- @param self          parley.github.Provider
--- @param _review       parley.DetectedReview
--- @param _discussion_id string
function GitHubProvider:resolve(_review, _discussion_id)
  local _ = self
  error("parley.github: resolve requires GraphQL (see POSTPONED.md)", 0)
end

--- Unresolve a discussion thread.
--- NOT IMPLEMENTED — requires GraphQL. See POSTPONED.md.
---
--- @param self          parley.github.Provider
--- @param _review       parley.DetectedReview
--- @param _discussion_id string
function GitHubProvider:unresolve(_review, _discussion_id)
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
--- @param _review    parley.DetectedReview
--- @param comment_id string
--- @param reaction   string  e.g. "+1", "heart"
function GitHubProvider:react(_review, comment_id, reaction)
  transport.fetch_viewer_login(self)
  local viewer = self._viewer_login or ""
  local base_url = repo_path(self) .. "/pulls/comments/" .. comment_id .. "/reactions"

  -- Fetch existing reactions of this type.
  local reactions = transport.gh_run(self, {
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
    transport.gh_run(self, {
      "gh",
      "api",
      "--method",
      "DELETE",
      base_url .. "/" .. tostring(existing_id),
    })
  else
    -- Add reaction.
    transport.gh_run(self, {
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
--- @param _review    parley.DetectedReview
--- @param comment_id string
--- @param body       parley.Body
--- @return parley.Comment
function GitHubProvider:edit(_review, comment_id, body)
  local url = repo_path(self) .. "/pulls/comments/" .. comment_id
  local raw = transport.gh_run(self, {
    "gh",
    "api",
    "--method",
    "PATCH",
    url,
    "-f",
    "body=" .. body.text,
  })
  return mapping.map_rest_comment(raw, self._viewer_login or "")
end

--- Delete a comment.
---
--- @param self       parley.github.Provider
--- @param _review    parley.DetectedReview
--- @param comment_id string
function GitHubProvider:delete(_review, comment_id)
  local url = repo_path(self) .. "/pulls/comments/" .. comment_id
  transport.gh_run(self, { "gh", "api", "--method", "DELETE", url })
end

--- Submit a PR-level review.
--- event must be one of: "approve", "request_changes", "comment".
---
--- @param self  parley.github.Provider
--- @param review parley.DetectedReview
--- @param event string
--- @param body  parley.Body
function GitHubProvider:submit_review(review, event, body)
  local gh_event = mapping.REVIEW_EVENT_MAP[event]
  assert(gh_event, string.format("parley.github: unknown review event: %q", event))

  local write_context = review.write_context
  local url = repo_path(self) .. "/pulls/" .. write_context.number .. "/reviews"
  transport.gh_run(self, {
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

--- Return a short label for use in progress messages, e.g. "github.com".
--- @param self parley.github.Provider
--- @return string
function GitHubProvider:progress_label()
  return self._host
end

-- ---------------------------------------------------------------------------
-- Registry helpers
-- ---------------------------------------------------------------------------

--- Parse a git remote URL into { host, owner, repo }, or nil if unrecognized.
---
--- Recognized forms (trailing ".git" and trailing "/" are stripped):
---   • SSH:        git@<host>:<owner>/<repo>(.git)?
---   • HTTPS/HTTP: https?://[user@]<host>/<owner>/<repo>(.git)?
---
--- Pure function exported for unit testing.
---
--- @param url string|nil
--- @return { host: string, owner: string, repo: string }|nil
function M._parse_remote_url(url)
  if type(url) ~= "string" or url == "" then
    return nil
  end

  local host, owner, repo

  -- SSH form: git@host:owner/repo[.git]
  host, owner, repo = url:match("^git@([^:]+):([^/]+)/(.+)$")

  -- HTTPS/HTTP form with embedded user: https?://user@host/owner/repo[.git]
  if not host then
    host, owner, repo = url:match("^https?://[^/@]+@([^/]+)/([^/]+)/(.+)$")
  end

  -- HTTPS/HTTP form without user: https?://host/owner/repo[.git]
  if not host then
    host, owner, repo = url:match("^https?://([^/@]+)/([^/]+)/(.+)$")
  end

  if not host or not owner or not repo or owner == "" or repo == "" then
    return nil
  end

  -- Strip trailing ".git" and any trailing slashes from repo.
  repo = repo:gsub("%.git$", ""):gsub("/+$", "")
  if repo == "" then
    return nil
  end

  return { host = host, owner = owner, repo = repo }
end

--- Detect whether a VcsInfo points at a GitHub repository.
---
--- Returns the opts table for M.new (host/owner/repo) on a match, or nil
--- when the remote URL is missing or not a recognised GitHub URL.  Only
--- github.com is recognised today; Enterprise hosts can be added later by
--- extending the host check.
---
--- @param vcs_info parley.VcsInfo
--- @return { host: string, owner: string, repo: string }|nil
function M.detect(vcs_info)
  if type(vcs_info) ~= "table" then
    return nil
  end
  local parsed = M._parse_remote_url(vcs_info.remote_url)
  if not parsed then
    return nil
  end
  if parsed.host ~= "github.com" then
    return nil
  end
  return parsed
end

return M
