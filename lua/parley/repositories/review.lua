--- Shared remote reviews with checkout-specific local projections.

local async = require("plenary.async")
local local_mappings = require("parley.repositories.local_mappings")
local cache = require("parley.cache")
local context_repository = require("parley.repositories.context")
local provider_repository = require("parley.repositories.provider")
local ui = require("parley.runtime.ui")

local M = {}

--- Shared remote review data; projections live in local_mappings.
--- @type table<string, table>
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

local function clone(snapshot)
  return snapshot and vim.deepcopy(snapshot) or nil
end

local keys = require("parley.repositories.review_keys")
local pr_cache_key = keys.pr
local discussions_cache_key = keys.discussions

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
    all_mappings = view.all_mappings or {},
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
  local all_mappings = local_mappings.get(ctx, shared)
  local current = context_repository.get(bufnr)
  if not current or not vim.deep_equal(current.vcs_info, ctx.vcs_info) or current.rel_path ~= rel_path then
    return nil
  end
  if not all_mappings then
    return nil
  end
  local mappings = {}
  for _, discussion in ipairs(file_discussions) do
    local mapping = all_mappings and all_mappings[discussion.id] or nil
    if mapping then
      mappings[discussion.id] = mapping
    end
  end
  return {
    discussions = file_discussions,
    mappings = mappings,
    all_mappings = all_mappings,
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
      if M._reviews[review_key] ~= shared then
        return
      end
      if M._bufnr_key[bufnr] == review_key then
        if view then
          M._views[bufnr] = view
          notify_subscribers(bufnr, composite(shared, view))
        else
          M.remap_async(bufnr)
        end
      end
    else
      M._views[bufnr] = nil
      notify_subscribers(bufnr, nil)
    end
  end
end

--- Publish to a single buffer only (used during initial registration when the
--- @param bufnr integer
--- @param shared table|nil
local function publish_to_bufnr(bufnr, shared)
  if shared then
    local key = M._bufnr_key[bufnr]
    local view = compute_view(bufnr, shared)
    if M._bufnr_key[bufnr] ~= key or M._reviews[key] ~= shared then
      return
    end
    if not view then
      M.remap_async(bufnr)
      return
    end
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

--- Restore shared review data from the on-disk cache. Returns a shared-shaped
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
    branch = branch,
    pr = pr,
    all_discussions = discussions_entry.data,
    summary = build_summary(discussions_entry.data),
    error = nil,
    head_sha = review.head_sha or "",
  }
end

--- Build the review key from a provider snapshot and buffer context.
--- @param provider_snapshot { provider: parley.Provider, opts: table }
--- @param ctx { vcs_info: parley.VcsInfo }
--- @return string|nil
M.make_key = keys.make

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
    M.detach(bufnr, true)
    return nil
  end

  local provider_snapshot = provider_repository.refresh(bufnr)
  if not provider_snapshot then
    publish_to_bufnr(bufnr, nil)
    M.detach(bufnr, true)
    return nil
  end

  local provider = provider_snapshot.provider
  local provider_opts = provider_snapshot.opts
  local branch = ctx.vcs_info.branch
  if not branch or branch == "" then
    publish_to_bufnr(bufnr, nil)
    M.detach(bufnr, true)
    return nil
  end

  local review_key = M.make_key(provider_snapshot, ctx)
  if not review_key then
    publish_to_bufnr(bufnr, nil)
    M.detach(bufnr, true)
    return nil
  end

  register_bufnr(bufnr, review_key)

  if M._in_flight[review_key] then
    if opts.force then
      M._pending_force[review_key] = true
    end
    local existing = M._reviews[review_key]
    if existing then
      publish_to_bufnr(bufnr, existing)
    end
    return clone(composite(M._reviews[review_key], M._views[bufnr]))
  end

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
      branch = branch,
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
      current.status = "error"
      current.error = tostring(result)
    else
      local err_shared = {
        status = "error",
        stale = false,
        review = nil,
        pr = nil,
        all_discussions = {},
        all_mappings = {},
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

--- Local refresh generations; remote data is not invalidated by buffer edits.
--- @type table<integer, integer>
M._remap_generation = {}

--- @param bufnr integer
function M.remap_async(bufnr)
  local generation = (M._remap_generation[bufnr] or 0) + 1
  M._remap_generation[bufnr] = generation
  vim.defer_fn(function()
    if M._remap_generation[bufnr] ~= generation or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    async.run(function()
      local ctx = context_repository.get(bufnr)
      local key = M._bufnr_key[bufnr]
      local shared = key and M._reviews[key]
      if not ctx or not ctx.vcs_info or not shared then
        return
      end
      if shared.branch and shared.branch ~= ctx.vcs_info.branch then
        publish_to_bufnr(bufnr, nil)
        M.detach(bufnr, true)
        return
      end
      local_mappings.invalidate(ctx.vcs_info)
      for sibling in pairs(M._key_bufnrs[key] or {}) do
        local other = context_repository.get(sibling)
        if other and other.vcs_info and local_mappings.key(other.vcs_info) == local_mappings.key(ctx.vcs_info) then
          publish_to_bufnr(sibling, shared)
        end
      end
    end)
  end, 150)
end

--- Detach one buffer without invalidating another checkout's remote review.
--- @param bufnr integer
--- @param preserve_subscribers? boolean
function M.detach(bufnr, preserve_subscribers)
  M._remap_generation[bufnr] = (M._remap_generation[bufnr] or 0) + 1
  local key = M._bufnr_key[bufnr]
  if key and M._key_bufnrs[key] then
    M._key_bufnrs[key][bufnr] = nil
  end
  M._bufnr_key[bufnr], M._views[bufnr] = nil, nil
  if not preserve_subscribers then
    M._subscribers[bufnr] = nil
  end
  local ctx = context_repository.get(bufnr)
  if ctx and ctx.vcs_info then
    local_mappings.invalidate(ctx.vcs_info)
    for sibling in pairs(M._key_bufnrs[key] or {}) do
      local other = context_repository.get(sibling)
      if other and other.vcs_info and local_mappings.key(other.vcs_info) == local_mappings.key(ctx.vcs_info) then
        M.remap_async(sibling)
      end
    end
  end
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

--- Subscribe to composite snapshot changes for a buffer.
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

--- Seed both shared and per-file data from a single composite snapshot.
--- @param bufnr integer
--- @param snapshot table|nil  same shape as the old _entries[bufnr]
--- @param review_key? string  defaults to "test/repository/branch"
function M._seed(bufnr, snapshot, review_key)
  review_key = review_key or "test/repository/branch"
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
    all_mappings = snapshot.all_mappings or snapshot.mappings or {},
  }
end

return M
