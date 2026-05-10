--- parley.repositories.review — review data repository.
---
--- Shared review data (PR, discussions) is keyed by a data-identity key
--- ("provider/owner/repo/branch"), not by bufnr. Per-file views (filtered
--- discussions, anchor mappings) are derived per buffer. Multiple buffers in
--- the same repo/branch share the underlying data and are all re-published
--- when a refresh completes.

local async = require("plenary.async")
local anchor = require("parley.anchor")
local cache = require("parley.cache")
local context_repository = require("parley.repositories.context")
local provider_repository = require("parley.repositories.provider")
local ui = require("parley.runtime.ui")

local M = {}

-- ---------------------------------------------------------------------------
-- Internal state
-- ---------------------------------------------------------------------------

--- Shared review data keyed by review_key ("provider/owner/repo/branch").
--- @type table<string, {
---   status: 'ready'|'error',
---   stale: boolean,
---   review: parley.DetectedReview|nil,
---   pr: parley.PR|nil,
---   all_discussions: parley.Discussion[],
---   summary: { unresolved_count: integer },
---   error: string|nil,
---   head_sha: string,
--- }>
M._reviews = {}

--- Per-file view keyed by bufnr.
--- @type table<integer, { discussions: parley.Discussion[], mappings: table<string, parley.anchor.Mapping> }>
M._views = {}

--- bufnr → review_key mapping.
--- @type table<integer, string>
M._bufnr_key = {}

--- review_key → set of bufnrs. Reverse index of _bufnr_key.
--- @type table<string, table<integer, boolean>>
M._key_bufnrs = {}

--- Reentrancy guard, keyed by review_key.
--- @type table<string, boolean>
M._in_flight = {}

--- Pending force-refresh, keyed by review_key.
--- @type table<string, boolean>
M._pending_force = {}

--- Per-buffer UI subscribers.
--- @type table<integer, table<integer, fun(snapshot: table|nil): nil>>
M._subscribers = {}
M._next_subscriber_id = 0

M._get_config = function()
  return require("parley").config
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function clone(snapshot)
  return snapshot and vim.deepcopy(snapshot) or nil
end

local function provider_name(provider)
  return provider._cache_provider or "github"
end

local function pr_cache_key(provider, opts, branch)
  return {
    provider = provider_name(provider),
    repository = opts.owner .. "/" .. opts.repo,
    subkey = "pr_branch_" .. branch,
  }
end

local function discussions_cache_key(provider, opts, pr_id)
  return {
    provider = provider_name(provider),
    repository = opts.owner .. "/" .. opts.repo,
    subkey = "discussions_" .. pr_id,
  }
end

local function filter_for_file(discussions, rel_path)
  local out = {}
  for _, discussion in ipairs(discussions) do
    if discussion.file == rel_path then
      out[#out + 1] = discussion
    end
  end
  return out
end

--- @param discussions parley.Discussion[]
--- @return { unresolved_count: integer }
local function build_summary(discussions)
  local unresolved_count = 0
  for _, discussion in ipairs(discussions) do
    if discussion.resolved ~= true then
      unresolved_count = unresolved_count + 1
    end
  end
  return { unresolved_count = unresolved_count }
end

--- Register a bufnr → review_key mapping. Handles branch switches by removing
--- the bufnr from its previous key's set.
--- @param bufnr integer
--- @param review_key string
local function register_bufnr(bufnr, review_key)
  local old_key = M._bufnr_key[bufnr]
  if old_key == review_key then
    return
  end
  -- Remove from old key's set.
  if old_key and M._key_bufnrs[old_key] then
    M._key_bufnrs[old_key][bufnr] = nil
    if next(M._key_bufnrs[old_key]) == nil then
      M._key_bufnrs[old_key] = nil
    end
  end
  M._bufnr_key[bufnr] = review_key
  if not M._key_bufnrs[review_key] then
    M._key_bufnrs[review_key] = {}
  end
  M._key_bufnrs[review_key][bufnr] = true
end

--- Build a composite snapshot (same shape as the old _entries[bufnr]) from
--- shared review data and a per-file view.
--- @param shared table|nil
--- @param view table|nil
--- @return table|nil
local function composite(shared, view)
  if not shared then
    return nil
  end
  view = view or { discussions = {}, mappings = {} }
  return {
    status = shared.status,
    stale = shared.stale,
    review = shared.review,
    pr = shared.pr,
    discussions = view.discussions,
    all_discussions = shared.all_discussions,
    mappings = view.mappings,
    summary = shared.summary,
    error = shared.error,
    head_sha = shared.head_sha,
  }
end

--- Compute the per-file view for a buffer from shared review data.
--- @param bufnr integer
--- @param shared table
--- @return { discussions: parley.Discussion[], mappings: table }
local function compute_view(bufnr, shared)
  local ctx = context_repository.get(bufnr)
  local rel_path = ctx and ctx.rel_path or nil
  if not rel_path then
    return { discussions = {}, mappings = {} }
  end
  local file_discussions = filter_for_file(shared.all_discussions or {}, rel_path)
  local vcs_root = ctx.vcs_info and ctx.vcs_info.root or ""
  return {
    discussions = file_discussions,
    mappings = anchor.map_discussions(vcs_root, shared.head_sha or "", file_discussions),
  }
end

--- Notify subscribers for a single buffer.
--- @param bufnr integer
--- @param snapshot table|nil
local function notify_subscribers(bufnr, snapshot)
  local subs = M._subscribers[bufnr]
  if not subs then
    return
  end
  local payload = clone(snapshot)
  for _, cb in pairs(subs) do
    ui.dispatch(function()
      cb(payload)
    end)
  end
end

--- Store shared data and re-publish per-file views to ALL buffers for this key.
--- @param review_key string
--- @param shared table|nil
local function publish_shared(review_key, shared)
  M._reviews[review_key] = shared
  local bufnrs = M._key_bufnrs[review_key]
  if not bufnrs then
    return
  end
  for bufnr in pairs(bufnrs) do
    if shared then
      local view = compute_view(bufnr, shared)
      M._views[bufnr] = view
      notify_subscribers(bufnr, composite(shared, view))
    else
      M._views[bufnr] = nil
      notify_subscribers(bufnr, nil)
    end
  end
end

--- Publish to a single buffer only (used during initial registration when the
--- buffer is not yet known to publish_shared's iteration).
--- @param bufnr integer
--- @param shared table|nil
local function publish_to_bufnr(bufnr, shared)
  if shared then
    local view = compute_view(bufnr, shared)
    M._views[bufnr] = view
    notify_subscribers(bufnr, composite(shared, view))
  else
    M._views[bufnr] = nil
    notify_subscribers(bufnr, nil)
  end
end

local function consume_pending_force(review_key)
  if not M._pending_force[review_key] then
    return false
  end
  M._pending_force[review_key] = nil
  return true
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Restore shared review data from the on-disk cache. Returns a shared-shaped
--- table (no per-file data) or nil when the cache is cold or incomplete.
--- @param bufnr integer
--- @param ctx table
--- @param provider_snapshot table
--- @return table|nil
local function restore_cached_snapshot(bufnr, ctx, provider_snapshot)
  local provider = provider_snapshot.provider
  local p_opts = provider_snapshot.opts
  local branch = ctx.vcs_info and ctx.vcs_info.branch or nil
  if not branch or branch == "" then
    return nil
  end

  local pr_entry = cache.get_async(pr_cache_key(provider, p_opts, branch))
  if not pr_entry or not pr_entry.data then
    return nil
  end

  local review = pr_entry.data.review
  local pr = review and review.pr or nil
  local pr_id = pr and pr.id or nil
  if not pr_id then
    return nil
  end

  local discussions_entry = cache.get_async(discussions_cache_key(provider, p_opts, pr_id))
  if not discussions_entry or not discussions_entry.data then
    return nil
  end

  provider_repository.store(bufnr, provider, p_opts)
  return {
    status = "ready",
    stale = true,
    review = review,
    pr = pr,
    all_discussions = discussions_entry.data,
    summary = build_summary(discussions_entry.data),
    error = nil,
    head_sha = review.head_sha or "",
  }
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Build the review key from a provider snapshot and buffer context.
--- @param provider_snapshot { provider: parley.Provider, opts: table }
--- @param ctx { vcs_info: parley.VcsInfo }
--- @return string|nil
function M.make_key(provider_snapshot, ctx)
  if not provider_snapshot or not provider_snapshot.provider or not provider_snapshot.opts then
    return nil
  end
  if not ctx or not ctx.vcs_info or not ctx.vcs_info.branch or ctx.vcs_info.branch == "" then
    return nil
  end
  local name = provider_name(provider_snapshot.provider)
  local opts = provider_snapshot.opts
  return name .. "/" .. opts.owner .. "/" .. opts.repo .. "/" .. ctx.vcs_info.branch
end

--- Check whether shared review data exists for the given key (in-memory).
--- @param review_key string
--- @return boolean
function M.has_review(review_key)
  return M._reviews[review_key] ~= nil
end

--- Check whether the on-disk cache has PR data for this branch.
--- Must be called from within a plenary.async coroutine.
--- @param provider parley.Provider
--- @param opts table
--- @param branch string
--- @return boolean
function M.has_cached_review(provider, opts, branch)
  local entry = cache.get_async(pr_cache_key(provider, opts, branch))
  return entry ~= nil and entry.data ~= nil
end

--- Get the composite snapshot for a buffer. Returns nil if the buffer has no
--- associated review data.
--- @param bufnr integer
--- @param opts? { ensure?: boolean }
--- @return table|nil
function M.get(bufnr, opts)
  opts = opts or {}
  local key = M._bufnr_key[bufnr]
  if not key then
    if opts.ensure then
      M.refresh_async(bufnr)
    end
    return nil
  end
  local shared = M._reviews[key]
  if not shared then
    if opts.ensure then
      M.refresh_async(bufnr)
    end
    return nil
  end
  return clone(composite(shared, M._views[bufnr]))
end

--- Refresh review data for the given buffer. Must be called from within a
--- plenary.async coroutine (network + disk I/O).
--- @param bufnr integer
--- @param opts? { force?: boolean }
--- @return table|nil
function M.refresh(bufnr, opts)
  opts = opts or {}

  local ctx = context_repository.refresh(bufnr)
  if not ctx or ctx.kind ~= "regular" or not ctx.vcs_info or not ctx.rel_path then
    publish_to_bufnr(bufnr, nil)
    return nil
  end

  local provider_snapshot = provider_repository.refresh(bufnr)
  if not provider_snapshot then
    publish_to_bufnr(bufnr, nil)
    return nil
  end

  local provider = provider_snapshot.provider
  local provider_opts = provider_snapshot.opts
  local branch = ctx.vcs_info.branch
  if not branch or branch == "" then
    publish_to_bufnr(bufnr, nil)
    return nil
  end

  local review_key = M.make_key(provider_snapshot, ctx)
  if not review_key then
    publish_to_bufnr(bufnr, nil)
    return nil
  end

  register_bufnr(bufnr, review_key)

  if M._in_flight[review_key] then
    if opts.force then
      M._pending_force[review_key] = true
    end
    -- If shared data already exists, publish a view for this new buffer.
    local existing = M._reviews[review_key]
    if existing then
      publish_to_bufnr(bufnr, existing)
    end
    return clone(composite(M._reviews[review_key], M._views[bufnr]))
  end

  -- Restore from disk cache (stale-while-revalidate).
  if not opts.force then
    local restored = restore_cached_snapshot(bufnr, ctx, provider_snapshot)
    if restored then
      publish_shared(review_key, restored)
    end
  end

  M._in_flight[review_key] = true
  local ok, result = pcall(function()
    local review = provider:detect_pr(ctx.vcs_info.root, branch)
    if review == nil then
      cache.invalidate_async(pr_cache_key(provider, provider_opts, branch))
      publish_shared(review_key, nil)
      return nil
    end

    cache.set_async(pr_cache_key(provider, provider_opts, branch), {
      review = review,
    })

    local discussions = provider:fetch_discussions(review)
    cache.set_async(discussions_cache_key(provider, provider_opts, review.pr.id), discussions)
    provider_repository.store(bufnr, provider, provider_opts)

    local shared = {
      status = "ready",
      stale = false,
      review = review,
      pr = review.pr,
      all_discussions = discussions,
      summary = build_summary(discussions),
      error = nil,
      head_sha = review.head_sha or "",
    }
    publish_shared(review_key, shared)
    return clone(composite(shared, M._views[bufnr]))
  end)
  M._in_flight[review_key] = nil

  if not ok then
    local current = M._reviews[review_key]
    if current then
      -- Stale data is already rendered; only mark the error without
      -- re-publishing (avoids a redundant render cycle).
      current.status = "error"
      current.error = tostring(result)
    else
      local err_shared = {
        status = "error",
        stale = false,
        review = nil,
        pr = nil,
        all_discussions = {},
        summary = { unresolved_count = 0 },
        error = tostring(result),
        head_sha = "",
      }
      publish_shared(review_key, err_shared)
    end
  end

  if consume_pending_force(review_key) then
    return M.refresh(bufnr, { force = true })
  end
  return clone(composite(M._reviews[review_key], M._views[bufnr]))
end

--- @param bufnr integer
--- @param opts? { force?: boolean }
function M.refresh_async(bufnr, opts)
  async.run(function()
    M.refresh(bufnr, opts)
  end)
end

--- Invalidate cached review data for a buffer's repo/branch.
--- @param bufnr integer
--- @param opts? { preserve_snapshot?: boolean }
function M.invalidate(bufnr, opts)
  opts = opts or {}
  local review_key = M._bufnr_key[bufnr]
  local ctx = context_repository.get(bufnr)
  local provider_snapshot = provider_repository.get(bufnr)
  local shared = review_key and M._reviews[review_key] or nil

  if ctx and provider_snapshot and shared and shared.pr and ctx.vcs_info and ctx.vcs_info.branch then
    local provider = provider_snapshot.provider
    local provider_opts = provider_snapshot.opts
    cache.invalidate(pr_cache_key(provider, provider_opts, ctx.vcs_info.branch))
    cache.invalidate(discussions_cache_key(provider, provider_opts, shared.pr.id))
  end
  if opts.preserve_snapshot ~= true and review_key then
    publish_shared(review_key, nil)
  end
end

--- Subscribe to snapshot changes for a buffer. The callback receives the
--- composite snapshot (same shape as get() returns) whenever data changes.
--- @param bufnr integer
--- @param cb fun(snapshot: table|nil): nil
--- @return fun(): nil unsubscribe
function M.subscribe(bufnr, cb)
  M._next_subscriber_id = M._next_subscriber_id + 1
  local id = M._next_subscriber_id
  if not M._subscribers[bufnr] then
    M._subscribers[bufnr] = {}
  end
  M._subscribers[bufnr][id] = cb
  return function()
    local subs = M._subscribers[bufnr]
    if not subs then
      return
    end
    subs[id] = nil
    if next(subs) == nil then
      M._subscribers[bufnr] = nil
    end
  end
end

-- ---------------------------------------------------------------------------
-- Test helpers
-- ---------------------------------------------------------------------------

--- Seed both shared and per-file data from a single composite snapshot.
--- For test use only.
--- @param bufnr integer
--- @param snapshot table|nil  same shape as the old _entries[bufnr]
--- @param review_key? string  defaults to "test/owner/repo/branch"
function M._seed(bufnr, snapshot, review_key)
  review_key = review_key or "test/owner/repo/branch"
  register_bufnr(bufnr, review_key)
  if not snapshot then
    M._reviews[review_key] = nil
    M._views[bufnr] = nil
    return
  end
  M._reviews[review_key] = {
    status = snapshot.status or "ready",
    stale = snapshot.stale or false,
    review = snapshot.review,
    pr = snapshot.pr or (snapshot.review and snapshot.review.pr or nil),
    all_discussions = snapshot.all_discussions or {},
    summary = snapshot.summary or build_summary(snapshot.all_discussions or {}),
    error = snapshot.error,
    head_sha = snapshot.head_sha or "",
  }
  M._views[bufnr] = {
    discussions = snapshot.discussions or {},
    mappings = snapshot.mappings or {},
  }
end

-- ---------------------------------------------------------------------------
-- Private: restore from disk cache
-- ---------------------------------------------------------------------------

return M
