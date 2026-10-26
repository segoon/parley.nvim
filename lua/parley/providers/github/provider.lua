--- parley.providers.github.provider — GitHub provider implementation.
--- Implements parley.Provider against the GitHub REST API via the `gh` CLI.
--- Network calls use `gh api` and `gh pr view`, which handle
--- authentication. Parley owns its explicit retry and cancellation policy.
--- Design notes:
---   • Transport: `gh api` subprocess via vim.system + plenary.async.
---   • Discussion IDs = root review-comment database ID (string).
---     This lets reply() pass it directly as `in_reply_to`.
---   • Thread resolution state and node ids come from a separate GraphQL
---     query (`gh api graphql`) correlated to REST-derived discussions by
---     root comment database id. resolve/unresolve call the corresponding
---     GraphQL mutation against the cached thread node id.
local dbg = require("parley.debug")
local mapping = require("parley.providers.github.mapping")
local transport = require("parley.providers.github.transport")

local M = {}

-- Type annotations

--- @class parley.github.WriteContext
--- @field head_sha string
--- @field number   integer

--- @class parley.github.Provider : parley.Provider
--- @field _host         string
--- @field _owner        string
--- @field _repo         string
--- @field _api_base     string
--- @field _runner? fun(cmd: string[]): table Test-only adapter to the callback executor.
--- @field _spawn        fun(
---   cmd: string[],
---   callback: fun(result: {code: integer, stdout: string, stderr: string})
--- ): vim.SystemObj|nil
--- @field _system function
--- @field _prepared? boolean
--- @field _session_generation? integer
--- @field _session_valid? boolean
--- @field _session_token? string
--- @field _session_context? string
--- @field _defer        fun(callback: fun(), timeout_ms: integer): uv_timer_t|nil
--- @field _config parley.GitHubProviderConfig
--- @field _auth         table
--- @field _viewer_login string|nil
--- @field _cache_provider string
--- @field _thread_node_ids table<string, string>  discussion id → GraphQL review-thread node id

-- Internal helpers

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

-- Provider object

--- @type parley.github.Provider
local GitHubProvider = { display_name = require("parley.providers.github.metadata").display_name }
GitHubProvider.__index = GitHubProvider
GitHubProvider.capabilities = require("parley.providers.github.capabilities").get
GitHubProvider.validate_comment_target = require("parley.providers.comment_target").validate
GitHubProvider.cache_identity = require("parley.providers.github.cache_identity").get
GitHubProvider.prepare = require("parley.providers.github.cache_identity").prepare
GitHubProvider.reaction_choices = require("parley.providers.github.reactions").choices
GitHubProvider.reaction_presentation = require("parley.providers.github.reactions").presentation

-- Constructor

--- Create a new GitHub provider.
--- Required opts: repository.
--- Optional opts: host (default "github.com"), api_base, _runner, _auth.
--- @param opts {
---   repository: string,
---   host?: string,
---   api_base?: string,
---   _runner?: fun(cmd: string[]): table,
---   _spawn?: fun(
---     cmd: string[],
---     callback: fun(result: {code: integer, stdout: string, stderr: string})
---   ): vim.SystemObj|nil,
---   _sleep?: fun(timeout_ms: integer): nil,
---   _defer?: fun(callback: fun(), timeout_ms: integer): uv_timer_t|nil,
---   config?: parley.GitHubProviderConfig,
---   _system?: fun(cmd: string[], opts: table, callback: fun(result: vim.SystemCompleted)): vim.SystemObj,
---   _auth?: table,
--- }
--- @return parley.github.Provider
function M.new(opts)
  opts = opts or {}
  local config = require("parley.providers.github.config").resolve(opts.config)
  assert(
    type(opts.repository) == "string" and opts.repository ~= "",
    "parley.github: opts.repository must be a non-empty string"
  )

  local owner, repo = opts.repository:match("^([^/]+)/([^/]+)$")
  assert(owner and repo, "parley.github: opts.repository must have the form 'owner/repo'")

  local host = opts.host or "github.com"
  local self
  local system = opts._system or vim.system

  local default_spawn = function(cmd, callback)
    local ui = require("parley.runtime.ui")
    return system(
      cmd,
      {
        text = true,
        timeout = transport.transport_config(self).timeout_ms,
        env = self._session_token and { GH_TOKEN = self._session_token, GH_ENTERPRISE_TOKEN = self._session_token }
          or nil,
      },
      ui.wrap(function(result)
        callback({ code = result.code, stdout = result.stdout or "", stderr = result.stderr or "" })
      end)
    )
  end

  self = setmetatable({
    _host = host,
    _owner = owner,
    _repo = repo,
    _api_base = opts.api_base or api_base_for_host(host),
    _runner = opts._runner,
    _system = system,
    _spawn = opts._spawn or (opts._runner and function(cmd, callback)
      callback(self._runner(cmd))
      return { kill = function() end }
    end) or default_spawn,
    _defer = opts._defer or (opts._sleep and function(callback, delay)
      opts._sleep(delay)
      callback()
    end) or vim.defer_fn,
    _config = config,
    _auth = opts._auth or require("parley.providers.github.auth"),
    _viewer_login = nil,
    _cache_provider = "github",
    _thread_node_ids = {},
  }, GitHubProvider)

  return self
end

-- parley.Provider interface

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

GitHubProvider.detect_pr = require("parley.providers.github.pull_request").detect

GitHubProvider.fetch_discussions = require("parley.providers.github.discussions").fetch

--- Post a new top-level review comment anchored to a file/line.
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
--- @param callback parley.WriteCallback
--- @return parley.CancelHandle
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
--- @param callback parley.WriteCallback
--- @return parley.CancelHandle
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

--- Look up the cached GraphQL review-thread node id for a discussion,
--- raising a clear error if it hasn't been populated by a prior
--- fetch_discussions() call.
--- @param self parley.github.Provider
--- @param discussion_id string
--- @return string
local function thread_node_id(self, discussion_id)
  local thread_id = self._thread_node_ids[discussion_id]
  if not thread_id then
    error(
      "parley.github: unknown review-thread id for discussion "
        .. tostring(discussion_id)
        .. "; refresh the review and retry",
      0
    )
  end
  return thread_id
end

--- Resolve a discussion thread via the GraphQL resolveReviewThread mutation.
--- @param self          parley.github.Provider
--- @param _review       parley.DetectedReview
--- @param discussion_id string
function GitHubProvider:resolve(_review, discussion_id)
  transport.gh_graphql(self, mapping.RESOLVE_THREAD_MUTATION, { id = thread_node_id(self, discussion_id) })
end

--- Start a cancellable resolve request.
--- @param self parley.github.Provider
--- @param _review parley.DetectedReview
--- @param discussion_id string
--- @param callback parley.WriteCallback
--- @return parley.CancelHandle
function GitHubProvider:begin_resolve(_review, discussion_id, callback)
  local ok, thread_id = pcall(thread_node_id, self, discussion_id)
  if not ok then
    callback({ ok = false, err = tostring(thread_id) })
    return { cancel = function() end }
  end
  return transport.gh_graphql_start(self, mapping.RESOLVE_THREAD_MUTATION, { id = thread_id }, callback)
end

--- Unresolve a discussion thread via the GraphQL unresolveReviewThread mutation.
--- @param self          parley.github.Provider
--- @param _review       parley.DetectedReview
--- @param discussion_id string
function GitHubProvider:unresolve(_review, discussion_id)
  transport.gh_graphql(self, mapping.UNRESOLVE_THREAD_MUTATION, { id = thread_node_id(self, discussion_id) })
end

--- Start a cancellable unresolve request.
--- @param self parley.github.Provider
--- @param _review parley.DetectedReview
--- @param discussion_id string
--- @param callback parley.WriteCallback
--- @return parley.CancelHandle
function GitHubProvider:begin_unresolve(_review, discussion_id, callback)
  local ok, thread_id = pcall(thread_node_id, self, discussion_id)
  if not ok then
    callback({ ok = false, err = tostring(thread_id) })
    return { cancel = function() end }
  end
  return transport.gh_graphql_start(self, mapping.UNRESOLVE_THREAD_MUTATION, { id = thread_id }, callback)
end

--- Toggle a reaction on a comment (add if absent, remove if present).
--- @param self       parley.github.Provider
--- @param _review    parley.DetectedReview
--- @param comment_id string
--- @param reaction   string  e.g. "+1", "heart"
function GitHubProvider:react(_review, comment_id, reaction)
  assert(require("parley.providers.github.reactions").supports(reaction), "unsupported GitHub reaction")
  transport.fetch_viewer_login(self)
  local viewer = self._viewer_login
  assert(viewer, "Could not determine the authenticated GitHub user; refresh the review and retry the reaction")
  local base_url = repo_path(self) .. "/pulls/comments/" .. comment_id .. "/reactions"

  -- Fetch existing reactions of this type.
  local reactions = transport.gh_run(self, {
    "gh",
    "api",
    "--paginate",
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
--- @param self       parley.github.Provider
--- @param _review    parley.DetectedReview
--- @param comment_id string
function GitHubProvider:delete(_review, comment_id)
  local url = repo_path(self) .. "/pulls/comments/" .. comment_id
  transport.gh_run(self, { "gh", "api", "--method", "DELETE", url })
end

--- Submit a PR-level review.
--- event must be one of: "approve", "request_changes", "comment".
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

-- Registry helpers

--- Parse a git remote URL into { host, owner, repo }, or nil if unrecognized.
--- Recognized forms (trailing ".git" and trailing "/" are stripped):
---   • SSH:        git@<host>:<owner>/<repo>(.git)?
---   • HTTPS/HTTP: https?://[user@]<host>/<owner>/<repo>(.git)?
--- Pure function exported for unit testing.
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
--- Returns the opts table for M.new (host/repository) on a match, or nil
--- when the remote URL is missing or not a recognised GitHub URL.  Only
--- github.com is recognised today; Enterprise hosts can be added later by
--- extending the host check.
--- @param vcs_info parley.VcsInfo
--- @return { host: string, repository: string }|nil
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
  return {
    host = parsed.host,
    repository = parsed.owner .. "/" .. parsed.repo,
  }
end

return M
