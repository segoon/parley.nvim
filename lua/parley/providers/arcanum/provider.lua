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
---   • resolve / unresolve / react / submit_review are not supported by the
---     Arcanum public API and raise an error.
---
--- Testability:
---   • _http_run / _http_start: injectable transport seams.
---   • _auth: injectable auth module.
---   • _sleep / _defer: injectable timing seams.
---   • config: explicit configuration snapshot.

local dbg = require("parley.debug")
local mapping = require("parley.providers.arcanum.mapping")
local transport = require("parley.providers.arcanum.transport")

local M = {}
local PR_DETAIL_FIELDS = "id,summary,status,url,author,vcs"

-- ---------------------------------------------------------------------------
-- Type annotations
-- ---------------------------------------------------------------------------

--- @class parley.arcanum.WriteContext
--- @field pr_id         integer          PR numeric ID
--- @field diff_id       integer|nil      Active diff numeric ID (nil before detect_pr resolves it)
--- @field diff_set_xid  string|nil       Active diff set xid (for comment anchoring)
--- @field changelist    table<string, string>  Map of file path → entry_id (populated lazily)

--- @class parley.arcanum.Provider : parley.Provider
--- @field _host         string
--- @field _token        string|nil
--- @field _auth         table
--- @field _sleep        fun(timeout_ms: integer): nil
--- @field _defer        fun(callback: fun(), timeout_ms: integer): uv_timer_t|nil
--- @field _config parley.ArcanumProviderConfig
--- @field _viewer_login string|nil
--- @field _cache_provider string

-- ---------------------------------------------------------------------------
-- Provider object
-- ---------------------------------------------------------------------------

--- @type parley.arcanum.Provider
local ArcanumProvider = { display_name = require("parley.providers.arcanum.metadata").display_name }
ArcanumProvider.__index = ArcanumProvider
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
--- Optional opts: host, _auth, _http_run, _http_start, _sleep, _defer, config.
---
--- @param opts {
---   branch?:       string,
---   login?:        string,
---   host?:         string,
---   _auth?:        table,
---   _sleep?:       fun(timeout_ms: integer): nil,
---   _defer?:       fun(callback: fun(), timeout_ms: integer): uv_timer_t|nil,
---   config?: parley.ArcanumProviderConfig,
--- }
--- @return parley.arcanum.Provider
function M.new(opts)
  opts = opts or {}
  local config = require("parley.providers.arcanum.config").resolve(opts.config)

  local await = require("parley.runtime.await")

  local self = setmetatable({
    _host = opts.host or config.host,
    _auth = opts._auth or require("parley.providers.arcanum.auth"),
    _sleep = opts._sleep or await.sleep,
    _defer = opts._defer or vim.defer_fn,
    _config = config,
    _viewer_login = opts.login or nil,
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

--- Resolve entry_id for a file path from the changelist cache.
--- Fetches the changelist if not yet cached.
--- @param self parley.arcanum.Provider
--- @param write_context parley.arcanum.WriteContext
--- @param file_path string  Repo-relative file path
--- @return string|nil  entry_id
local function resolve_entry_id(self, write_context, file_path)
  -- Use cached changelist if available
  if write_context.changelist and write_context.changelist[file_path] then
    return write_context.changelist[file_path]
  end

  if not write_context.diff_id then
    return nil
  end

  -- Fetch changelist and cache it
  local ok, data =
    pcall(transport.http_run, self, "GET", "/v2/public/diff/" .. tostring(write_context.diff_id) .. "/changelist")
  if not ok or not data then
    dbg.trace("arcanum.provider", "resolve_entry_id: failed to fetch changelist: " .. tostring(data))
    return nil
  end

  if not write_context.changelist then
    write_context.changelist = {}
  end
  for _, entry in ipairs(data) do
    if entry.path and entry.entry_id then
      write_context.changelist[entry.path] = entry.entry_id
    end
  end

  return write_context.changelist[file_path]
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
  ensure_token(self)

  local search_branch = branch or self._branch or ""
  if search_branch == "" then
    dbg.trace("arcanum.provider", "detect_pr: no branch, skipping")
    return nil
  end

  dbg.trace("arcanum.provider", "detect_pr: searching for branch=" .. search_branch)

  -- Search for open PRs with this branch
  local search_body = {
    limit = 1,
    filter = {
      user_branch_prefix = search_branch,
      state = { published = true },
    },
  }

  local data = transport.http_run(self, "POST", "/v1/pull-requests/cursor", search_body)
  if not data or not data.pull_requests or #data.pull_requests == 0 then
    dbg.trace("arcanum.provider", "detect_pr: no PR found for branch=" .. search_branch)
    return nil
  end

  -- Cursor search returns minimal PR objects, so fetch full PR details before
  -- matching by branch or mapping fields.
  local raw_pr = nil
  for _, pr in ipairs(data.pull_requests) do
    local pr_id = pr.id
    if pr_id then
      local full_pr =
        transport.http_run(self, "GET", "/v1/pull-requests/" .. tostring(pr_id) .. "?fields=" .. PR_DETAIL_FIELDS)
      local vcs = full_pr and full_pr.vcs or {}
      if vcs.from_branch == search_branch then
        raw_pr = full_pr
        break
      end
      dbg.trace(
        "arcanum.provider",
        "detect_pr: candidate pr_id=" .. tostring(pr_id) .. " from_branch=" .. tostring(vcs.from_branch)
      )
    else
      dbg.trace("arcanum.provider", "detect_pr: candidate without id from cursor response")
    end
  end

  if not raw_pr then
    dbg.trace("arcanum.provider", "detect_pr: no exact branch match for=" .. search_branch)
    return nil
  end

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
  if ok_diff and diff_data then
    diff_id = diff_data.id
    -- The active diff's xid is its GSID field in v1 — but the changelist
    -- endpoint uses a numeric id, not xid.  We use diff_id (integer) for
    -- the changelist call; diff_set_xid (string) is used in comment anchoring.
    -- The v1 active diff response has gsid which is the xid.
    diff_set_xid = diff_data.gsid
    dbg.trace(
      "arcanum.provider",
      "detect_pr: diff_id=" .. tostring(diff_id) .. " diff_set_xid=" .. tostring(diff_set_xid)
    )
  else
    dbg.trace("arcanum.provider", "detect_pr: could not fetch active diff: " .. tostring(diff_data))
  end

  -- Determine head_sha from the active diff's commit_ids
  local head_sha = ""
  if ok_diff and diff_data and diff_data.commit_ids then
    head_sha = diff_data.commit_ids.head or ""
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
  ensure_token(self)

  local pr_id = review.write_context and review.write_context.pr_id or tonumber(review.pr.id)
  if not pr_id then
    return {}
  end

  local data = transport.http_run(self, "GET", "/v1/public/review-requests/" .. tostring(pr_id) .. "/comments")
  if not data then
    return {}
  end

  local viewer = self._viewer_login or ""
  dbg.trace("arcanum.provider", "fetch_discussions: viewer=" .. vim.inspect(viewer) .. " #comments=" .. tostring(#data))

  local discussions = mapping.group_comments_into_discussions(data, viewer)
  dbg.trace("arcanum.provider", "fetch_discussions: #discussions=" .. tostring(#discussions))
  return discussions
end

--- Post a new top-level review comment anchored to a file/line.
---
--- Requires resolving the entry_id for the file from the active diff changelist.
--- If entry_id cannot be resolved, falls back to a PR-level comment.
---
--- @param self   parley.arcanum.Provider
--- @param review parley.DetectedReview
--- @param file   string
--- @param anchor parley.Anchor
--- @param body   parley.Body
--- @return parley.Comment
function ArcanumProvider:post_top_level_comment(review, file, anchor, body)
  ensure_token(self)

  local write_context = review.write_context
  local pr_id = write_context.pr_id

  dbg.trace(
    "arcanum.provider",
    "post_top_level_comment: pr=" .. tostring(pr_id) .. " file=" .. tostring(file) .. " anchor=" .. vim.inspect(anchor)
  )

  -- Resolve entry_id for this file path
  local entry_id = resolve_entry_id(self, write_context, file)

  local request_body = {
    content = body.text,
  }

  if entry_id and write_context.diff_set_xid then
    -- Anchored comment on a specific file/line
    request_body.entry_id = entry_id
    request_body.diff_line = anchor.start_line
    request_body.diff_side = "new"
    request_body.diff_set_xid = write_context.diff_set_xid
    if anchor.end_line and anchor.end_line ~= anchor.start_line then
      request_body.diff_size = anchor.end_line - anchor.start_line + 1
    end
  else
    dbg.trace(
      "arcanum.provider",
      "post_top_level_comment: no entry_id for file=" .. tostring(file) .. ", posting as PR-level comment"
    )
  end

  local data =
    transport.http_run(self, "POST", "/v1/public/review-requests/" .. tostring(pr_id) .. "/comments", request_body)

  -- Response is wrapped in CreateReviewRequestCommentResponse { data: CommentDto }
  -- transport.http_run already unwraps to data
  local raw_comment = data
  if not raw_comment then
    error("parley.arcanum: post_top_level_comment: empty response", 0)
  end

  return mapping.map_comment(raw_comment, self._viewer_login or "")
end

--- Start a cancellable top-level comment request.
--- @param self     parley.arcanum.Provider
--- @param review   parley.DetectedReview
--- @param file     string
--- @param anchor   parley.Anchor
--- @param body     parley.Body
--- @param callback fun(result: { ok: boolean, comment?: parley.Comment, err?: string, cancelled?: boolean }): nil
--- @return { cancel: fun(): nil }
function ArcanumProvider:begin_post_top_level_comment(review, file, anchor, body, callback)
  ensure_token(self)

  local write_context = review.write_context
  local pr_id = write_context.pr_id

  local entry_id = resolve_entry_id(self, write_context, file)

  local request_body = {
    content = body.text,
  }

  if entry_id and write_context.diff_set_xid then
    request_body.entry_id = entry_id
    request_body.diff_line = anchor.start_line
    request_body.diff_side = "new"
    request_body.diff_set_xid = write_context.diff_set_xid
    if anchor.end_line and anchor.end_line ~= anchor.start_line then
      request_body.diff_size = anchor.end_line - anchor.start_line + 1
    end
  end

  return transport.http_start(
    self,
    "POST",
    "/v1/public/review-requests/" .. tostring(pr_id) .. "/comments",
    request_body,
    function(result)
      if not result.ok then
        callback(result)
        return
      end
      local raw = result.data
      if not raw then
        callback({ ok = false, err = "parley.arcanum: empty response from post_top_level_comment" })
        return
      end
      callback({ ok = true, comment = mapping.map_comment(raw, self._viewer_login or "") })
    end
  )
end

--- Post a reply to an existing discussion.
---
--- @param self           parley.arcanum.Provider
--- @param _review        parley.DetectedReview
--- @param _discussion    parley.Discussion
--- @param parent_comment parley.Comment
--- @param body           parley.Body
--- @return parley.Comment
function ArcanumProvider:reply(_review, _discussion, parent_comment, body)
  ensure_token(self)

  local data = transport.http_run(
    self,
    "POST",
    "/v1/public/review-requests-comments/" .. parent_comment.id .. "/replies",
    { content = body.text }
  )

  if not data then
    error("parley.arcanum: reply: empty response", 0)
  end

  return mapping.map_comment(data, self._viewer_login or "")
end

--- Start a cancellable reply request.
--- @param self           parley.arcanum.Provider
--- @param _review        parley.DetectedReview
--- @param _discussion    parley.Discussion
--- @param parent_comment parley.Comment
--- @param body           parley.Body
--- @param callback fun(result: { ok: boolean, comment?: parley.Comment, err?: string, cancelled?: boolean }): nil
--- @return { cancel: fun(): nil }
function ArcanumProvider:begin_reply(_review, _discussion, parent_comment, body, callback)
  ensure_token(self)

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
      local raw = result.data
      if not raw then
        callback({ ok = false, err = "parley.arcanum: empty response from reply" })
        return
      end
      callback({ ok = true, comment = mapping.map_comment(raw, self._viewer_login or "") })
    end
  )
end

--- Resolve a discussion thread.
--- NOT IMPLEMENTED — Arcanum public API does not expose a resolve endpoint.
---
--- @param self          parley.arcanum.Provider
--- @param _review       parley.DetectedReview
--- @param _discussion_id string
function ArcanumProvider:resolve(_review, _discussion_id)
  local _ = self
  error("parley.arcanum: resolve is not supported by the Arcanum public API", 0)
end

--- Unresolve a discussion thread.
--- NOT IMPLEMENTED — Arcanum public API does not expose an unresolve endpoint.
---
--- @param self          parley.arcanum.Provider
--- @param _review       parley.DetectedReview
--- @param _discussion_id string
function ArcanumProvider:unresolve(_review, _discussion_id)
  local _ = self
  error("parley.arcanum: unresolve is not supported by the Arcanum public API", 0)
end

--- Toggle a reaction on a comment.
--- NOT IMPLEMENTED — Arcanum public API does not expose a reaction mutation endpoint.
---
--- @param self        parley.arcanum.Provider
--- @param _review     parley.DetectedReview
--- @param _comment_id string
--- @param _reaction   string
function ArcanumProvider:react(_review, _comment_id, _reaction)
  local _ = self
  error("parley.arcanum: reactions are not supported by the Arcanum public API", 0)
end

--- Edit an existing comment body.
---
--- @param self        parley.arcanum.Provider
--- @param _review     parley.DetectedReview
--- @param comment_id  string
--- @param body        parley.Body
--- @return parley.Comment
function ArcanumProvider:edit(_review, comment_id, body)
  ensure_token(self)

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
  ensure_token(self)
  transport.http_run(self, "DELETE", "/v1/public/review-requests-comments/" .. comment_id)
end

--- Submit a PR-level review verdict.
--- NOT IMPLEMENTED — Arcanum public API does not expose a review verdict endpoint.
---
--- @param self   parley.arcanum.Provider
--- @param _review parley.DetectedReview
--- @param _event string
--- @param _body  parley.Body
function ArcanumProvider:submit_review(_review, _event, _body)
  local _ = self
  error("parley.arcanum: submit_review is not supported by the Arcanum public API", 0)
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
