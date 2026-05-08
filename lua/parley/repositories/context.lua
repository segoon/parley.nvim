--- parley.repositories.context — buffer context repository.

local async = require("plenary.async")
local buffer_context = require("parley.buffer_context")

local M = {}

--- @type table<integer, parley.BufferContext & { status: 'ready', rel_path: string|nil }>
M._entries = {}

--- @type table<integer, table<integer, fun(snapshot: table|nil): nil>>
M._subscribers = {}
M._next_subscriber_id = 0

--- @param snapshot table|nil
local function clone(snapshot)
  return snapshot and vim.deepcopy(snapshot) or nil
end

--- @param bufnr integer
--- @param snapshot table|nil
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

--- @param ctx parley.BufferContext
--- @return string|nil
local function rel_path_for(ctx)
  if ctx.kind ~= "regular" or not ctx.path or not ctx.vcs_info then
    return nil
  end
  local root = ctx.vcs_info.root
  if ctx.path:sub(1, #root + 1) == root .. "/" then
    return ctx.path:sub(#root + 2)
  end
  return nil
end

--- @param bufnr integer
--- @return table|nil
function M.get(bufnr, opts)
  opts = opts or {}
  local snapshot = M._entries[bufnr]
  if not snapshot and opts.ensure then
    M.refresh_async(bufnr)
  end
  return clone(snapshot)
end

--- @param bufnr integer
--- @return table|nil
function M.refresh(bufnr)
  local ctx = buffer_context.classify(bufnr)
  local snapshot = vim.tbl_extend("force", ctx, {
    status = "ready",
    rel_path = rel_path_for(ctx),
  })
  publish(bufnr, snapshot)
  return clone(snapshot)
end

--- @param bufnr integer
function M.refresh_async(bufnr)
  async.run(function()
    M.refresh(bufnr)
  end)
end

--- @param bufnr integer
function M.invalidate(bufnr)
  publish(bufnr, nil)
end

--- @param bufnr integer
--- @param cb fun(snapshot: table|nil): nil
--- @return fun(): nil
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
