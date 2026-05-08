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
--- @field _spawn        fun(cmd: string[], callback: fun(result: {code: integer, stdout: string, stderr: string})): vim.SystemObj|nil
--- @field _sleep        fun(timeout_ms: integer): nil
--- @field _defer        fun(callback: fun(), timeout_ms: integer): uv_timer_t|nil
--- @field _get_config   fun(): parley.Config|nil
--- @field _auth         table
--- @field _pr_cache     table<string, parley.github.PrCache>
--- @field _viewer_login string|nil
--- @field _cache_provider string

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

local DEFAULT_TIMEOUT_MS = 5000
local DEFAULT_RETRY_COUNT = 2
local DEFAULT_RETRY_BASE_DELAY_MS = 250
local DEFAULT_RETRY_MAX_DELAY_MS = 2000

local RETRYABLE_ERROR_PATTERNS = {
  "i/o timeout",
  "tls handshake timeout",
  "connection reset",
  "connection refused",
  "no such host",
  "temporary failure in name resolution",
  "timeout awaiting response headers",
  "context deadline exceeded",
  "network is unreachable",
  "software caused connection abort",
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

---@param self parley.github.Provider
---@return { timeout_ms: integer, retry_count: integer, retry_base_delay_ms: integer, retry_max_delay_ms: integer }
local function transport_config(self)
  local config = self._get_config and self._get_config() or nil
  local github = config and config.providers and config.providers.github or {}
  return {
    timeout_ms = github.timeout_ms or DEFAULT_TIMEOUT_MS,
    retry_count = github.retry_count or DEFAULT_RETRY_COUNT,
    retry_base_delay_ms = github.retry_base_delay_ms or DEFAULT_RETRY_BASE_DELAY_MS,
    retry_max_delay_ms = github.retry_max_delay_ms or DEFAULT_RETRY_MAX_DELAY_MS,
  }
end

---@param attempt integer
---@param cfg { retry_base_delay_ms: integer, retry_max_delay_ms: integer }
---@return integer
local function retry_delay_ms(attempt, cfg)
  return math.min(cfg.retry_base_delay_ms * (2 ^ math.max(0, attempt - 1)), cfg.retry_max_delay_ms)
end

---@param stderr string|nil
---@return boolean
local function is_retryable_error(stderr)
  local text = (stderr or ""):lower()
  for _, pattern in ipairs(RETRYABLE_ERROR_PATTERNS) do
    if text:find(pattern, 1, true) then
      return true
    end
  end
  return false
end

---@param result { code: integer, stderr: string|nil }
---@return boolean
local function is_retryable_failure(result)
  return result.code == 124 or is_retryable_error(result.stderr)
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

--- Normalize a line/range value into start/end lines.
--- @param line parley.LineRange
--- @return integer, integer|nil
local function normalize_line(line)
  if type(line) == "number" then
    assert(line > 0, "parley.github: line must be > 0")
    return line, nil
  end

  assert(type(line) == "table", "parley.github: line must be an integer or { start, end } range")
  assert(#line == 2, "parley.github: line range must contain exactly two integers")

  local first = assert(tonumber(line[1]), "parley.github: line range start must be a number")
  local second = assert(tonumber(line[2]), "parley.github: line range end must be a number")
  assert(first > 0 and second > 0, "parley.github: line range values must be > 0")

  if first <= second then
    return first, second
  end
  return second, first
end

--- Build form fields for a top-level comment anchor.
--- @param file string
--- @param line parley.LineRange
--- @param body parley.Body
--- @param commit_id string
--- @return string[]
local function build_top_level_fields(file, line, body, commit_id)
  local start_line, end_line = normalize_line(line)
  local fields = {
    "-f",
    "body=" .. body.text,
    "-f",
    "commit_id=" .. commit_id,
    "-f",
    "path=" .. file,
    "-f",
    "side=RIGHT",
  }

  if end_line and end_line ~= start_line then
    fields[#fields + 1] = "-F"
    fields[#fields + 1] = "start_line=" .. tostring(start_line)
    fields[#fields + 1] = "-f"
    fields[#fields + 1] = "start_side=RIGHT"
    fields[#fields + 1] = "-F"
    fields[#fields + 1] = "line=" .. tostring(end_line)
  else
    fields[#fields + 1] = "-F"
    fields[#fields + 1] = "line=" .. tostring(start_line)
    fields[#fields + 1] = "-f"
    fields[#fields + 1] = "subject_type=line"
  end

  return fields
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
  local cfg = transport_config(self)
  local attempts = cfg.retry_count + 1
  local result

  for attempt = 1, attempts do
    result = runner(cmd)
    if result.code == 0 then
      break
    end
    if attempt >= attempts or not is_retryable_failure(result) then
      error(string.format("parley.github: gh command failed (exit %d): %s", result.code, result.stderr or ""), 0)
    end
    self._sleep(retry_delay_ms(attempt, cfg))
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

--- Start a cancellable gh CLI request.
--- @param self parley.github.Provider
--- @param cmd string[]
--- @param callback fun(result: { ok: boolean, data?: table, err?: string, cancelled?: boolean }): nil
--- @return { cancel: fun(): nil }
local function gh_start(self, cmd, callback)
  local completed = false
  local cancelled = false
  local handle = nil
  local retry_timer = nil
  local cfg = transport_config(self)
  local attempts = cfg.retry_count + 1
  local attempt = 0

  local function clear_retry_timer()
    if not retry_timer then
      return
    end
    if retry_timer.stop then
      pcall(function()
        retry_timer:stop()
      end)
    end
    if retry_timer.close then
      pcall(function()
        retry_timer:close()
      end)
    end
    retry_timer = nil
  end

  local function finish(result)
    if completed then
      return
    end
    completed = true
    clear_retry_timer()
    callback(result)
  end

  local function start_attempt()
    attempt = attempt + 1
    handle = self._spawn(cmd, function(result)
      handle = nil
      if completed then
        return
      end

      if cancelled then
        finish({ ok = false, cancelled = true })
        return
      end

      if result.code ~= 0 then
        if attempt < attempts and is_retryable_failure(result) then
          retry_timer = self._defer(function()
            retry_timer = nil
            if completed or cancelled then
              return
            end
            start_attempt()
          end, retry_delay_ms(attempt, cfg))
          return
        end
        finish({
          ok = false,
          err = string.format("parley.github: gh command failed (exit %d): %s", result.code, result.stderr or ""),
        })
        return
      end

      local stdout = result.stdout or ""
      if stdout == "" then
        finish({ ok = true, data = nil })
        return
      end

      local ok_decode, decoded = pcall(vim.json.decode, stdout)
      if not ok_decode then
        finish({ ok = false, err = string.format("parley.github: failed to decode JSON response: %s", stdout) })
        return
      end

      finish({ ok = true, data = decoded })
    end)
  end

  start_attempt()

  return {
    cancel = function()
      if completed or cancelled then
        return
      end
      cancelled = true
      clear_retry_timer()
      if handle and handle.kill then
        pcall(function()
          handle:kill(15)
        end)
        return
      end
      finish({ ok = false, cancelled = true })
    end,
  }
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
---   _runner?: fun(cmd: string[]): table, _spawn?: fun(cmd: string[], callback: fun(result: {code: integer, stdout: string, stderr: string})): vim.SystemObj|nil,
---   _sleep?: fun(timeout_ms: integer): nil, _defer?: fun(callback: fun(), timeout_ms: integer): uv_timer_t|nil,
---   _get_config?: fun(): parley.Config|nil, _system?: fun(cmd: string[], opts: table, callback: fun(result: vim.SystemCompleted)): vim.SystemObj,
---   _auth?: table }
--- @return parley.github.Provider
function M.new(opts)
  opts = opts or {}
  assert(type(opts.owner) == "string" and opts.owner ~= "", "parley.github: opts.owner must be a non-empty string")
  assert(type(opts.repo) == "string" and opts.repo ~= "", "parley.github: opts.repo must be a non-empty string")

  local host = opts.host or "github.com"
  local self
  local system = opts._system or vim.system

  local default_runner = async.wrap(function(cmd, callback)
    system(cmd, { text = true, timeout = transport_config(self).timeout_ms }, function(result)
      vim.schedule(function()
        callback({ code = result.code, stdout = result.stdout or "", stderr = result.stderr or "" })
      end)
    end)
  end, 2)

  local default_spawn = function(cmd, callback)
    return system(cmd, { text = true, timeout = transport_config(self).timeout_ms }, function(result)
      vim.schedule(function()
        callback({ code = result.code, stdout = result.stdout or "", stderr = result.stderr or "" })
      end)
    end)
  end

  self = setmetatable({
    _host = host,
    _owner = opts.owner,
    _repo = opts.repo,
    _api_base = opts.api_base or api_base_for_host(host),
    _runner = opts._runner or default_runner,
    _spawn = opts._spawn or default_spawn,
    _sleep = opts._sleep or function(timeout_ms)
      vim.wait(timeout_ms, function()
        return false
      end)
    end,
    _defer = opts._defer or vim.defer_fn,
    _get_config = opts._get_config or function()
      return require("parley").config
    end,
    _auth = opts._auth or require("parley.providers.github.auth"),
    _pr_cache = {},
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
--- @param line parley.LineRange
--- @param body parley.Body
--- @return parley.Comment
function GitHubProvider:post_top_level_comment(pr, file, line, body)
  local cached = self._pr_cache[pr.id]
  assert(cached, "parley.github: detect_pr must be called before post_top_level_comment (pr not in cache)")

  local url = repo_path(self) .. "/pulls/" .. cached.number .. "/comments"
  local cmd = { "gh", "api", "--method", "POST", url }
  vim.list_extend(cmd, build_top_level_fields(file, line, body, cached.head_sha))
  local raw = gh_run(self, cmd)

  return map_rest_comment(raw, self._viewer_login or "")
end

--- Start a cancellable top-level comment request.
--- @param self parley.github.Provider
--- @param pr parley.PR
--- @param file string
--- @param line parley.LineRange
--- @param body parley.Body
--- @param callback fun(result: { ok: boolean, comment?: parley.Comment, err?: string, cancelled?: boolean }): nil
--- @return { cancel: fun(): nil }
function GitHubProvider:begin_post_top_level_comment(pr, file, line, body, callback)
  local cached = self._pr_cache[pr.id]
  assert(cached, "parley.github: detect_pr must be called before post_top_level_comment (pr not in cache)")

  local url = repo_path(self) .. "/pulls/" .. cached.number .. "/comments"
  local cmd = { "gh", "api", "--method", "POST", url }
  vim.list_extend(cmd, build_top_level_fields(file, line, body, cached.head_sha))
  return gh_start(self, cmd, function(result)
    if not result.ok then
      callback(result)
      return
    end
    callback({ ok = true, comment = map_rest_comment(result.data, self._viewer_login or "") })
  end)
end

--- Post a reply to an existing discussion.
--- discussion_id is the root comment's database id (used as in_reply_to).
---
--- @param self          parley.github.Provider
--- @param pr            parley.PR
--- @param discussion_id string  Root comment database id
--- @param parent_comment_id string
--- @param body          parley.Body
--- @return parley.Comment
function GitHubProvider:reply(pr, discussion_id, parent_comment_id, body)
  local cached = self._pr_cache[pr.id]
  assert(cached, "parley.github: detect_pr must be called before reply (pr not in cache)")

  local url = repo_path(self) .. "/pulls/" .. cached.number .. "/comments"
  local _ = discussion_id
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
    "in_reply_to=" .. parent_comment_id,
  })

  return map_rest_comment(raw, self._viewer_login or "")
end

--- Start a cancellable reply request.
--- @param self parley.github.Provider
--- @param pr parley.PR
--- @param discussion_id string
--- @param parent_comment_id string
--- @param body parley.Body
--- @param callback fun(result: { ok: boolean, comment?: parley.Comment, err?: string, cancelled?: boolean }): nil
--- @return { cancel: fun(): nil }
function GitHubProvider:begin_reply(pr, discussion_id, parent_comment_id, body, callback)
  local cached = self._pr_cache[pr.id]
  assert(cached, "parley.github: detect_pr must be called before reply (pr not in cache)")

  local url = repo_path(self) .. "/pulls/" .. cached.number .. "/comments"
  local _ = discussion_id
  return gh_start(self, {
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
    "in_reply_to=" .. parent_comment_id,
  }, function(result)
    if not result.ok then
      callback(result)
      return
    end
    callback({ ok = true, comment = map_rest_comment(result.data, self._viewer_login or "") })
  end)
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

--- Return the head commit SHA cached for `pr` by detect_pr.
--- Returns nil when detect_pr has not been called for this PR.
---
--- @param self parley.github.Provider
--- @param pr   parley.PR
--- @return string|nil
function GitHubProvider:head_sha(pr)
  local cached = self._pr_cache[pr.id]
  return cached and cached.head_sha or nil
end

--- Export provider write context for cached stale startup restores.
--- @param self parley.github.Provider
--- @param pr parley.PR
--- @return { number: integer, head_sha: string }|nil
function GitHubProvider:export_write_context(pr)
  local cached = self._pr_cache[pr.id]
  if not cached then
    return nil
  end
  return {
    number = cached.number,
    head_sha = cached.head_sha,
  }
end

--- Import provider write context previously exported by export_write_context.
--- @param self parley.github.Provider
--- @param pr parley.PR
--- @param ctx { number: integer, head_sha: string }|nil
function GitHubProvider:import_write_context(pr, ctx)
  if not ctx then
    return
  end
  self._pr_cache[pr.id] = {
    number = ctx.number,
    head_sha = ctx.head_sha,
  }
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
