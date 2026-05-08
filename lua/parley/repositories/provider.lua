--- parley.repositories.provider — provider repository.

local async = require("plenary.async")
local context_repository = require("parley.repositories.context")
local registry = require("parley.registry")
local ui = require("parley.runtime.ui")

local M = {}

--- @type table<integer, { status: 'ready', provider: parley.Provider, opts: table }>
M._entries = {}

--- @type table<integer, table<integer, fun(snapshot: table|nil): nil>>
M._subscribers = {}
M._next_subscriber_id = 0

local function clone(snapshot)
  return snapshot and { status = snapshot.status, provider = snapshot.provider, opts = vim.deepcopy(snapshot.opts) }
    or nil
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

  for _, spec in ipairs(registry.registered()) do
    local opts = spec.detect(ctx.vcs_info)
    if opts ~= nil then
      return {
        status = "ready",
        provider = spec.factory(opts),
        opts = opts,
      }
    end
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
  local snapshot = resolve_provider(ctx)
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

--- @param bufnr integer
--- @param provider parley.Provider
--- @param opts table
function M.store(bufnr, provider, opts)
  publish(bufnr, { status = "ready", provider = provider, opts = vim.deepcopy(opts) })
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
