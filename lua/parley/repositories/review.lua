--- parley.repositories.review — review data repository.

local async = require("plenary.async")
local anchor = require("parley.anchor")
local cache = require("parley.cache")
local context_repository = require("parley.repositories.context")
local provider_repository = require("parley.repositories.provider")

local M = {}

--- @type table<integer, {
---   status: 'ready'|'error',
---   stale: boolean,
---   pr: parley.PR|nil,
---   discussions: parley.Discussion[],
---   all_discussions: parley.Discussion[],
---   mappings: table<string, parley.anchor.Mapping>,
---   summary: { unresolved_count: integer },
---   error: string|nil,
---   head_sha: string,
--- }>
M._entries = {}
M._in_flight = {}
M._pending_force = {}

--- @type table<integer, table<integer, fun(snapshot: table|nil): nil>>
M._subscribers = {}
M._next_subscriber_id = 0

M._get_config = function()
  return require("parley").config
end

local function clone(snapshot)
  return snapshot and vim.deepcopy(snapshot) or nil
end

local function publish(bufnr, snapshot)
  M._entries[bufnr] = snapshot
  local subs = M._subscribers[bufnr]
  if not subs then
    return
  end
  local payload = clone(snapshot)
  for _, cb in pairs(subs) do
    cb(payload)
  end
end

local function consume_pending_force(bufnr)
  if not M._pending_force[bufnr] then
    return false
  end
  M._pending_force[bufnr] = nil
  return true
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
    -- TODO(segoon): GitHub REST review comments do not expose thread resolution,
    -- so this currently approximates unresolved_count as all fetched threads.
    -- Replace this with provider-backed resolved state once GraphQL threads land.
    if discussion.resolved ~= true then
      unresolved_count = unresolved_count + 1
    end
  end
  return { unresolved_count = unresolved_count }
end

local function build_snapshot(ctx, head_sha, pr, discussions)
  local file_discussions = filter_for_file(discussions, ctx.rel_path)
  return {
    status = "ready",
    stale = false,
    pr = pr,
    discussions = file_discussions,
    all_discussions = discussions,
    mappings = anchor.map_discussions(ctx.vcs_info.root, head_sha, file_discussions),
    summary = build_summary(discussions),
    error = nil,
    head_sha = head_sha,
  }
end

local function restore_cached_snapshot(bufnr, ctx, provider_snapshot)
  local provider = provider_snapshot.provider
  local opts = provider_snapshot.opts
  local branch = ctx.vcs_info and ctx.vcs_info.branch or nil
  if not branch or branch == "" then
    return nil
  end

  local pr_entry = cache.get(pr_cache_key(provider, opts, branch))
  if not pr_entry or not pr_entry.data then
    return nil
  end

  local pr = pr_entry.data.pr
  local write_context = pr_entry.data.write_context
  if pr and provider.import_write_context and write_context then
    provider:import_write_context(pr, write_context)
  end

  local pr_id = (pr and pr.id) or pr_entry.data.id
  if not pr_id then
    return nil
  end

  local discussions_entry = cache.get(discussions_cache_key(provider, opts, pr_id))
  if not discussions_entry or not discussions_entry.data then
    return nil
  end

  local file_discussions = filter_for_file(discussions_entry.data, ctx.rel_path)
  provider_repository.store(bufnr, provider, opts)
  return {
    status = "ready",
    stale = true,
    pr = pr,
    discussions = file_discussions,
    all_discussions = discussions_entry.data,
    mappings = anchor.map_discussions(ctx.vcs_info.root, pr_entry.data.head_sha or "", file_discussions),
    summary = build_summary(discussions_entry.data),
    error = nil,
    head_sha = pr_entry.data.head_sha or (write_context and write_context.head_sha) or "",
  }
end

function M.get(bufnr, opts)
  opts = opts or {}
  local snapshot = M._entries[bufnr]
  if not snapshot and opts.ensure then
    M.refresh_async(bufnr)
  end
  return clone(snapshot)
end

function M.refresh(bufnr, opts)
  opts = opts or {}
  if M._in_flight[bufnr] then
    if opts.force then
      M._pending_force[bufnr] = true
    end
    return clone(M._entries[bufnr])
  end

  local ctx = context_repository.refresh(bufnr)
  if not ctx or ctx.kind ~= "regular" or not ctx.vcs_info or not ctx.rel_path then
    publish(bufnr, nil)
    return nil
  end

  local provider_snapshot = provider_repository.refresh(bufnr)
  if not provider_snapshot then
    publish(bufnr, nil)
    return nil
  end

  local provider = provider_snapshot.provider
  local provider_opts = provider_snapshot.opts
  local branch = ctx.vcs_info.branch
  if not branch or branch == "" then
    publish(bufnr, nil)
    return nil
  end

  if not opts.force then
    local restored = restore_cached_snapshot(bufnr, ctx, provider_snapshot)
    if restored then
      publish(bufnr, restored)
    end
  end

  M._in_flight[bufnr] = true
  local ok, result = pcall(function()
    local pr = provider:detect_pr(ctx.vcs_info.root, branch)
    if pr == nil then
      cache.invalidate(pr_cache_key(provider, provider_opts, branch))
      publish(bufnr, nil)
      return nil
    end

    local head_sha = (provider.head_sha and provider:head_sha(pr)) or ""
    local write_context = provider.export_write_context and provider:export_write_context(pr) or nil
    cache.set(pr_cache_key(provider, provider_opts, branch), {
      pr = pr,
      head_sha = head_sha,
      write_context = write_context,
    })

    local discussions = provider:fetch_discussions(pr)
    cache.set(discussions_cache_key(provider, provider_opts, pr.id), discussions)
    provider_repository.store(bufnr, provider, provider_opts)
    local snapshot = build_snapshot(ctx, head_sha, pr, discussions)
    publish(bufnr, snapshot)
    return snapshot
  end)
  M._in_flight[bufnr] = nil

  if not ok then
    local current = M._entries[bufnr]
    if current then
      current.status = "error"
      current.error = tostring(result)
    else
      publish(bufnr, {
        status = "error",
        stale = false,
        pr = nil,
        discussions = {},
        all_discussions = {},
        mappings = {},
        summary = { unresolved_count = 0 },
        error = tostring(result),
        head_sha = "",
      })
    end
  end

  if consume_pending_force(bufnr) then
    return M.refresh(bufnr, { force = true })
  end
  return clone(M._entries[bufnr])
end

function M.refresh_async(bufnr, opts)
  async.run(function()
    M.refresh(bufnr, opts)
  end)
end

--- @param bufnr integer
--- @param opts? { preserve_snapshot?: boolean }
function M.invalidate(bufnr, opts)
  opts = opts or {}
  local ctx = context_repository.get(bufnr)
  local provider_snapshot = provider_repository.get(bufnr)
  local snapshot = M._entries[bufnr]
  if ctx and provider_snapshot and snapshot and snapshot.pr and ctx.vcs_info and ctx.vcs_info.branch then
    local provider = provider_snapshot.provider
    local provider_opts = provider_snapshot.opts
    cache.invalidate(pr_cache_key(provider, provider_opts, ctx.vcs_info.branch))
    cache.invalidate(discussions_cache_key(provider, provider_opts, snapshot.pr.id))
  end
  if opts.preserve_snapshot ~= true then
    publish(bufnr, nil)
  end
end

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

return M
