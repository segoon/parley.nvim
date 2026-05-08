--- parley.ui_states.discussion — discussion UI state.

local M = {}

M._entries = {}
M._subscribers = {}
M._next_subscriber_id = 0

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

function M.get(bufnr)
  return clone(M._entries[bufnr])
end

function M.set(bufnr, snapshot)
  publish(bufnr, snapshot and vim.deepcopy(snapshot) or nil)
end

function M.patch(bufnr, patch)
  local current = M._entries[bufnr] or {}
  publish(bufnr, vim.tbl_deep_extend("force", current, patch))
end

function M.clear(bufnr)
  publish(bufnr, nil)
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
