--- parley.providers.arcanum.provider — Arcanum provider implementation.
---
--- Implements parley.Provider against the Arcanum public REST API.
--- All network calls are made via parley.http (plenary.curl) with
--- OAuth token authentication.
---
--- Design notes:
---   • Transport: direct HTTPS calls via parley.http + parley.arcanum.transport.
---   • PR detection: POST /v1/pull-requests/cursor filtered by branch.
---   • Discussion fetching: GET /v1/public/review-requests/{pr_id}/comments.
---   • Anchored comment posting requires resolving entry_id from the active diff
---     changelist; these are cached in write_context after detect_pr.
---   • Issue resolution uses public comment PATCH; reactions and review submission
---     are not implemented in this provider.
---
--- Testability:
---   • transport.http_run / transport.http_start: injectable transport seams.
---   • _auth: injectable auth module.
---   • scheduler._now / scheduler._defer: injectable timing seams.
---   • config: explicit configuration snapshot.

local dbg = require("parley.debug")
local mapping = require("parley.providers.arcanum.mapping")
local transport = require("parley.providers.arcanum.transport")

local M = {}
local session = require("parley.providers.arcanum.session")

-- ---------------------------------------------------------------------------
-- Type annotations
-- ---------------------------------------------------------------------------

--- @class parley.arcanum.WriteContext
--- @field pr_id         integer          PR numeric ID
--- @field diff_id       integer|nil      Active diff numeric ID (nil before detect_pr resolves it)
--- @field diff_set_xid  string|nil       Active diff set xid (for comment anchoring)
--- @field changelist_diff_id integer|nil Diff owning cached entry IDs
--- @field changelist    table<string, string>  Map of file path → entry_id (populated lazily)

--- @class parley.arcanum.Provider : parley.Provider
--- @field _host         string
--- @field _token        string|nil
--- @field _auth         table
--- @field _config parley.ArcanumProviderConfig
--- @field _viewer_login string|nil Verified API account
--- @field _arc_login string|nil Local Arc account, never used for ownership
--- @field _verified_host string|nil
--- @field _verified_token string|nil
--- @field _cache_provider string

-- ---------------------------------------------------------------------------
-- Provider object
-- ---------------------------------------------------------------------------

--- @type parley.arcanum.Provider
local ArcanumProvider = { display_name = require("parley.providers.arcanum.metadata").display_name }
ArcanumProvider.__index = ArcanumProvider
ArcanumProvider.prepare = session.prepare
ArcanumProvider.capabilities = require("parley.providers.arcanum.capabilities").get
ArcanumProvider.validate_comment_target = require("parley.providers.comment_target").validate
ArcanumProvider.cache_identity = require("parley.providers.arcanum.cache_identity").get
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
    _cache_provider = "arcanum",
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

--- Map a creation response without losing completion to malformed server fields.
--- @param raw any
--- @param viewer string
--- @return parley.Comment
local function map_reply(raw, viewer)
  local ok, comment = pcall(function()
    assert(
      type(raw) == "table" and tostring(raw.id):match("^%-?%d+$") and type(raw.content) == "string",
      "invalid reply response"
    )
    return mapping.map_comment(raw, viewer)
  end)
  if not ok then
    error(
      "Arcanum returned an incomplete reply response. "
        .. "Check the review before retrying; the reply may have been sent.",
      0
    )
  end
  return comment
end

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
  session.require_verified(self)

  local pr = mapping.map_pr(raw_pr)
  local pr_id = raw_pr.id

  dbg.trace("arcanum.provider", "detect_pr: found pr_id=" .. tostring(pr_id))

  -- Fetch the active diff to get diff_id and diff_set_xid for anchoring
  local diff_id = nil
  local diff_set_xid = nil
  local ok_diff, diff_data = pcall(
    transport.http_run,
    self,
    "GET",
    "/v1/pull-requests/" .. tostring(pr_id) .. "/active-diff?fields=id,commit_ids(head)"
  )
  if ok_diff and type(diff_data) == "table" then
    if require("parley.providers.arcanum.inline").valid_diff_id(diff_data.id) then
      diff_id = diff_data.id
      diff_set_xid = tostring(diff_id)
    end
    dbg.trace(
      "arcanum.provider",
      "detect_pr: diff_id=" .. tostring(diff_id) .. " diff_set_xid=" .. tostring(diff_set_xid)
    )
  else
    dbg.trace("arcanum.provider", "detect_pr: could not fetch active diff: " .. tostring(diff_data))
  end

  -- Determine head_sha from the active diff's commit_ids
  local head_sha = ""
  if ok_diff and type(diff_data) == "table" and type(diff_data.commit_ids) == "table" then
    local head = diff_data.commit_ids.head
    head_sha = type(head) == "string" and head or ""
  end

  --- @type parley.arcanum.WriteContext
  local write_context = {
    pr_id = pr_id,
    diff_id = diff_id,
    diff_set_xid = diff_set_xid,
    changelist = {},
  }

  return {
    pr = pr,
    head_sha = head_sha,
    write_context = write_context,
  }
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

  local data = transport.http_run(self, "GET", "/v1/public/review-requests/" .. tostring(pr_id) .. "/comments")
  if not data then
    return {}
  end

  session.require_verified(self)
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
--- @param _review        parley.DetectedReview
--- @param _discussion    parley.Discussion
--- @param parent_comment parley.Comment
--- @param body           parley.Body
--- @return parley.Comment
function ArcanumProvider:reply(_review, _discussion, parent_comment, body)
  session.require_verified(self)

  local data = transport.http_run(
    self,
    "POST",
    "/v1/public/review-requests-comments/" .. parent_comment.id .. "/replies",
    { content = body.text },
    { retry_policy = "create" }
  )

  return map_reply(data, self._viewer_login or "")
end

--- Start a cancellable reply request.
--- @param self           parley.arcanum.Provider
--- @param _review        parley.DetectedReview
--- @param _discussion    parley.Discussion
--- @param parent_comment parley.Comment
--- @param body           parley.Body
--- @param callback parley.WriteCallback
--- @return parley.CancelHandle
function ArcanumProvider:begin_reply(_review, _discussion, parent_comment, body, callback)
  session.require_verified(self)

  return transport.http_start(
    self,
    "POST",
    "/v1/public/review-requests-comments/" .. parent_comment.id .. "/replies",
    { content = body.text },
    function(result)
      if not result.ok then
        callback(result)
        return
      end
      local ok, comment = pcall(map_reply, result.data, self._viewer_login or "")
      callback(ok and { ok = true, comment = comment } or { ok = false, uncertain = true, err = tostring(comment) })
    end,
    { retry_policy = "create" }
  )
end

local resolution = require("parley.providers.arcanum.resolution")
ArcanumProvider.resolve = resolution.resolve
ArcanumProvider.unresolve = resolution.unresolve
ArcanumProvider.begin_resolve = resolution.begin_resolve
ArcanumProvider.begin_unresolve = resolution.begin_unresolve

--- Toggle a reaction on a comment.
--- NOT IMPLEMENTED — plugin reaction API integration is pending.
---
--- @param self        parley.arcanum.Provider
--- @param _review     parley.DetectedReview
--- @param _comment_id string
--- @param _reaction   string
function ArcanumProvider:react(_review, _comment_id, _reaction)
  local _ = self
  error("parley.arcanum: reaction changes are not implemented in Parley", 0)
end

--- Edit an existing comment body.
---
--- @param self        parley.arcanum.Provider
--- @param _review     parley.DetectedReview
--- @param comment_id  string
--- @param body        parley.Body
--- @return parley.Comment
function ArcanumProvider:edit(_review, comment_id, body)
  session.require_verified(self)

  local data =
    transport.http_run(self, "PATCH", "/v1/public/review-requests-comments/" .. comment_id, { content = body.text })

  if not data then
    error("parley.arcanum: edit: empty response", 0)
  end

  return mapping.map_comment(data, self._viewer_login or "")
end

--- Delete a comment.
---
--- @param self        parley.arcanum.Provider
--- @param _review     parley.DetectedReview
--- @param comment_id  string
function ArcanumProvider:delete(_review, comment_id)
  session.require_verified(self)
  transport.http_run(self, "DELETE", "/v1/public/review-requests-comments/" .. comment_id)
end

--- Submit a PR-level review verdict.
--- NOT IMPLEMENTED — plugin review API integration is pending.
---
--- @param self   parley.arcanum.Provider
--- @param _review parley.DetectedReview
--- @param _event string
--- @param _body  parley.Body
function ArcanumProvider:submit_review(_review, _event, _body)
  local _ = self
  error("parley.arcanum: review submission is not implemented in Parley", 0)
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
