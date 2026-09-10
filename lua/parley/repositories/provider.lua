--- parley.repositories.provider — provider repository.

local async = require("plenary.async")
local context_repository = require("parley.repositories.context")
local registry = require("parley.registry")
local identity = require("parley.cache_identity")
local ui = require("parley.runtime.ui")

local M = {}

--- @type table<integer, parley.ProviderSnapshot>
M._entries = {}

--- @type table<integer, table<integer, fun(snapshot: table|nil): nil>>
M._subscribers = {}
M._next_subscriber_id = 0

local function clone(snapshot)
  if not snapshot then
    return nil
  end
  local result = vim.deepcopy(snapshot)
  result.provider = snapshot.provider
  return result
end

local function publish(bufnr, snapshot)
  M._entries[bufnr] = snapshot
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

local function resolve_provider(ctx)
  if not ctx or ctx.kind ~= "regular" or not ctx.vcs_info then
    return nil
  end

  local provider, opts = registry.resolve_with_opts(ctx.vcs_info)
  if provider then
    if provider.prepare then
      provider:prepare(ctx.vcs_info)
    end
    return identity.snapshot(provider, opts)
  end
  return nil
end

function M.get(bufnr, opts)
  opts = opts or {}
  local snapshot = M._entries[bufnr]
  if not snapshot and opts.ensure then
    M.refresh_async(bufnr)
  end
  return clone(snapshot)
end

function M.refresh(bufnr)
  local ctx = context_repository.get(bufnr) or context_repository.refresh(bufnr)
  local ok, snapshot = pcall(function()
    local resolved = resolve_provider(ctx)
    if not vim.deep_equal(context_repository.get(bufnr), ctx) then
      error("Repository context changed during provider preparation; refresh the review", 0)
    end
    return resolved
  end)
  if not ok then
    publish(bufnr, nil)
    error(snapshot, 0)
  end
  publish(bufnr, snapshot)
  return clone(snapshot)
end

function M.refresh_async(bufnr)
  async.run(function()
    M.refresh(bufnr)
  end)
end

function M.invalidate(bufnr)
  publish(bufnr, nil)
end

--- Store a provider with a newly resolved identity; requires a Plenary coroutine.
--- @param bufnr integer
--- @param provider parley.Provider
--- @param opts table
function M.store(bufnr, provider, opts)
  local ok, snapshot = pcall(function()
    if provider.prepare then
      provider:prepare((context_repository.get(bufnr) or {}).vcs_info)
    end
    return identity.snapshot(provider, opts)
  end)
  if not ok then
    publish(bufnr, nil)
    error(snapshot, 0)
  end
  publish(bufnr, snapshot)
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
