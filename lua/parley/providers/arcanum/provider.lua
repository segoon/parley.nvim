--- parley.providers.arcanum.provider — Arcanum provider implementation.
---
--- Implements parley.Provider against the Arcanum public REST API.
--- Supported operations use ya tool arcanum; discussion reads and review verdicts
--- retain HTTPS. Both executors share scheduling, deadlines, and session guards.
---
--- Design notes:
---   • Transport: CLI/HTTPS selection through the provider-owned transport.
---   • PR detection: POST /v1/pull-requests/cursor filtered by branch.
---   • Discussion fetching: GET /v1/public/review-requests/{pr_id}/comments.
---   • Anchored comment posting requires resolving entry_id from the active diff
---     changelist; these are cached in write_context after detect_pr.
---   • Issues/reactions use CLI commands; explicit verdicts retain plugin APIs.
---
--- Testability:
---   • transport.request_run / transport.request_start: injectable transport seams.
---   • _auth: injectable auth module.
---   • scheduler._now / scheduler._defer: injectable timing seams.
---   • config: explicit configuration snapshot.

local dbg = require("parley.debug")
local mapping = require("parley.providers.arcanum.mapping")
local transport = require("parley.providers.arcanum.transport")

local M = {}
local session = require("parley.providers.arcanum.session")
local comment_write = require("parley.providers.arcanum.comment_write")

-- ---------------------------------------------------------------------------
-- Type annotations
-- ---------------------------------------------------------------------------

--- @class parley.arcanum.WriteContext
--- @field pr_id         integer          PR numeric ID
--- @field diff_id       integer|nil      Active diff numeric ID (nil before detect_pr resolves it)
--- @field review_data? table Validated plugin reviewer verdicts and remaining approval count
--- @field changelist_diff_id integer|nil Diff owning cached entry IDs
--- @field changelist    table<string, string>  Map of file path → entry_id (populated lazily)

--- @class parley.arcanum.Provider : parley.Provider
--- @field _host         string
--- @field _token        string|nil
--- @field _auth         table
--- @field _config parley.ArcanumProviderConfig
--- @field _viewer_login string|nil Arc account used for ownership
--- @field _arc_login string|nil Local Arc account from arc info
--- @field _session_host string|nil
--- @field _session_token string|nil

-- ---------------------------------------------------------------------------
-- Provider object
-- ---------------------------------------------------------------------------

--- @type parley.arcanum.Provider
local ArcanumProvider = { display_name = require("parley.providers.arcanum.metadata").display_name }
ArcanumProvider.__index = ArcanumProvider
ArcanumProvider.prepare = session.prepare
ArcanumProvider.capabilities = require("parley.providers.arcanum.capabilities").get
ArcanumProvider.validate_comment_target = require("parley.providers.arcanum.target").validate
ArcanumProvider.cache_identity = require("parley.providers.arcanum.cache_identity").get
ArcanumProvider.review_actions = require("parley.providers.arcanum.review_actions").choices
ArcanumProvider.begin_review_action = require("parley.providers.arcanum.review_actions").start
ArcanumProvider.begin_set_reaction = require("parley.providers.arcanum.reactions").start
ArcanumProvider.reaction_choices = require("parley.providers.arcanum.reactions").choices
ArcanumProvider.reaction_presentation = require("parley.providers.arcanum.reactions").presentation

-- ---------------------------------------------------------------------------
-- Constructor
-- ---------------------------------------------------------------------------

--- Create a new Arcanum provider.
---
--- Required opts: branch (the current arc remote branch id), login (the arc user login).
--- Optional opts: host, _auth, config.
---
--- @param opts {
---   branch?:       string,
---   login?:        string,
---   host?:         string,
---   _auth?:        table,
---   config?: parley.ArcanumProviderConfig,
--- }
--- @return parley.arcanum.Provider
function M.new(opts)
  opts = opts or {}
  local config = require("parley.providers.arcanum.config").resolve(
    vim.tbl_extend("force", opts.config or {}, opts.host and { host = opts.host } or {})
  )

  local self = setmetatable({
    _host = config.host,
    _auth = opts._auth or require("parley.providers.arcanum.auth"),
    _config = config,
    _arc_login = opts.login or nil,
    -- Detected from vcs_info at detect() time
    _branch = opts.branch or nil,
  }, ArcanumProvider)

  -- Resolve token eagerly so it can be used in headers
  local token = self._auth.read_token()
  self._token = token

  return self
end

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Ensure the OAuth token is loaded.
--- @param self parley.arcanum.Provider
local function ensure_token(self)
  if not self._token then
    local token, err = self._auth.read_token()
    if not token then
      error(string.format("parley.arcanum: auth failed: %s", err or "unknown error"), 0)
    end
    self._token = token
  end
end

-- ---------------------------------------------------------------------------
-- parley.Provider interface
-- ---------------------------------------------------------------------------

--- Return the authentication token.
--- @param self parley.arcanum.Provider
--- @return string
function ArcanumProvider:auth()
  ensure_token(self)
  return self._token
end

--- Detect an open PR for the given branch.
--- Uses POST /v1/pull-requests/cursor to search by branch name.
---
--- @param self        parley.arcanum.Provider
--- @param _repo_root  string  (unused — not needed for Arcanum)
--- @param branch      string  Arc remote branch id (e.g. "users/login/feature")
--- @return parley.DetectedReview|nil
function ArcanumProvider:detect_pr(_repo_root, branch)
  local search_branch = branch or self._branch or ""
  if search_branch == "" then
    return nil
  end
  session.prepare(self)
  local raw_pr = require("parley.providers.arcanum.discovery").find(self, search_branch)
  if not raw_pr then
    return nil
  end
  session.require_current(self)

  local pr = mapping.map_pr(raw_pr)
  local pr_id = raw_pr.id

  dbg.trace("arcanum.provider", "detect_pr: found pr_id=" .. tostring(pr_id))

  local ok_diff, data = pcall(
    transport.request_run,
    self,
    "GET",
    "/v1/pull-requests/" .. tostring(pr_id) .. "/active-diff?fields=id,commit_ids(base,head,merge)"
  )
  local diff = ok_diff and type(data) == "table" and data or {}
  local commits = type(diff.commit_ids) == "table" and diff.commit_ids or {}
  --- @param name string
  --- @return string
  local function revision(name)
    return type(commits[name]) == "string" and commits[name] or ""
  end
  local diff_id = require("parley.providers.arcanum.inline").valid_diff_id(diff.id) and diff.id or nil
  local review = {
    pr = pr,
    head_sha = revision("head"),
    base_sha = revision("base"),
    review_sha = revision("merge"),
    snapshot_id = tostring(diff_id or "unavailable"),
    write_context = { pr_id = pr_id, diff_id = diff_id, changelist = {} },
  }
  dbg.trace("arcanum.provider", "review revisions: " .. vim.inspect({
    diff = diff_id,
    head = review.head_sha,
    base = review.base_sha,
    merge = review.review_sha,
  }))
  require("parley.providers.arcanum.review_actions").load(self, review)
  return review
end

--- Fetch all discussions for a PR.
--- Uses GET /v1/public/review-requests/{pr_id}/comments.
---
--- @param self   parley.arcanum.Provider
--- @param review parley.DetectedReview
--- @return parley.Discussion[]
function ArcanumProvider:fetch_discussions(review)
  session.prepare(self)

  local pr_id = review.write_context and review.write_context.pr_id or tonumber(review.pr.id)
  if not pr_id then
    return {}
  end

  local data = transport.request_run(self, "GET", "/v1/public/review-requests/" .. tostring(pr_id) .. "/comments")
  if not data then
    return {}
  end

  session.require_current(self)
  local viewer = self._viewer_login or ""
  dbg.trace("arcanum.provider", "fetch_discussions: viewer=" .. vim.inspect(viewer) .. " #comments=" .. tostring(#data))

  local discussions = mapping.group_comments_into_discussions(data, viewer, review)
  dbg.trace("arcanum.provider", "fetch_discussions: #discussions=" .. tostring(#discussions))
  return discussions
end

ArcanumProvider.post_top_level_comment = require("parley.providers.arcanum.inline").run
ArcanumProvider.begin_post_top_level_comment = require("parley.providers.arcanum.inline").start

--- Post a reply to an existing discussion.
---
--- @param self           parley.arcanum.Provider
--- @param review        parley.DetectedReview
--- @param discussion    parley.Discussion
--- @param parent_comment parley.Comment
--- @param body           parley.Body
--- @return parley.Comment|nil Acknowledged writes without data are reconciled by refresh.
function ArcanumProvider:reply(review, discussion, parent_comment, body)
  local result = require("parley.runtime.await").callback(function(callback)
    self:begin_reply(review, discussion, parent_comment, body, callback)
  end)
  if not result.ok then
    error(result.err or "Arcanum reply cancelled", 0)
  end
  return result.comment
end

--- Start a cancellable reply request.
--- @param self           parley.arcanum.Provider
--- @param review        parley.DetectedReview
--- @param _discussion    parley.Discussion
--- @param parent_comment parley.Comment
--- @param body           parley.Body
--- @param callback parley.WriteCallback
--- @return parley.CancelHandle
function ArcanumProvider:begin_reply(review, _discussion, parent_comment, body, callback)
  session.require_current(self)

  return comment_write.start(
    self,
    "POST",
    "/v1/public/review-requests-comments/" .. parent_comment.id .. "/replies",
    { content = body.text },
    callback,
    { retry_policy = "create", pr_id = comment_write.pr_id(review) }
  )
end

local resolution = require("parley.providers.arcanum.resolution")
ArcanumProvider.resolve = resolution.resolve
ArcanumProvider.unresolve = resolution.unresolve
ArcanumProvider.begin_resolve = resolution.begin_resolve
ArcanumProvider.begin_unresolve = resolution.begin_unresolve

ArcanumProvider.react = require("parley.providers.arcanum.reactions").run

--- Edit an existing comment body.
---
--- @param self        parley.arcanum.Provider
--- @param review     parley.DetectedReview
--- @param comment_id  string
--- @param body        parley.Body
--- @return parley.Comment|nil Acknowledged writes without data are reconciled by refresh.
function ArcanumProvider:edit(review, comment_id, body)
  session.require_current(self)

  local result = require("parley.runtime.await").callback(function(callback)
    comment_write.start(
      self,
      "PATCH",
      "/v1/public/review-requests-comments/" .. comment_id,
      { content = body.text },
      callback,
      { pr_id = comment_write.pr_id(review) }
    )
  end)
  if not result.ok then
    error(result.err or "Arcanum edit failed", 0)
  end
  return result.comment
end

--- Delete a comment.
---
--- @param self        parley.arcanum.Provider
--- @param review     parley.DetectedReview
--- @param comment_id  string
function ArcanumProvider:delete(review, comment_id)
  session.require_current(self)
  transport.request_run(
    self,
    "DELETE",
    "/v1/public/review-requests-comments/" .. comment_id,
    nil,
    { pr_id = comment_write.pr_id(review) }
  )
end

--- Submit a PR-level review verdict.
--- Body/event transactions are not equivalent to explicit plugin review actions.
---
--- @param self   parley.arcanum.Provider
--- @param _review parley.DetectedReview
--- @param _event string
--- @param _body  parley.Body
function ArcanumProvider:submit_review(_review, _event, _body)
  local _ = self
  error("Use :Parley review actions; Arcanum review messages are unsupported", 0)
end

--- Return a short label for use in progress messages.
--- @param self parley.arcanum.Provider
--- @return string
function ArcanumProvider:progress_label()
  return self._host
end

-- ---------------------------------------------------------------------------
-- Registry helpers
-- ---------------------------------------------------------------------------

--- Detect whether a VcsInfo points at an Arc repository.
---
--- Returns the opts table for M.new on a match, or nil when the VcsInfo is
--- not an Arc repo.
---
--- The vcs_detector for Arc stores the user login as:
---   remote_url = "arc://<login>"
--- We parse that back here to extract the login.
---
--- @param vcs_info parley.VcsInfo
--- @return { branch: string|nil, login: string|nil, repository: string }|nil
function M.detect(vcs_info)
  if type(vcs_info) ~= "table" then
    return nil
  end
  if vcs_info.vcs ~= "arc" then
    return nil
  end

  -- Extract login from remote_url "arc://<login>"
  local login = nil
  if type(vcs_info.remote_url) == "string" then
    login = vcs_info.remote_url:match("^arc://(.+)$")
  end

  return {
    branch = vcs_info.branch,
    login = login,
    repository = "arcanum",
  }
end

return M
