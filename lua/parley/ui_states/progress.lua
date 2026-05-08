--- parley.ui_states.progress — global progress UI state.

local M = {}

M._entries = {}
M._subscribers = {}
M._next_subscriber_id = 0

local function clone(value)
  return value and vim.deepcopy(value) or nil
end

local function sorted_entries()
  local entries = {}
  for _, entry in pairs(M._entries) do
    entries[#entries + 1] = clone(entry)
  end
  table.sort(entries, function(left, right)
    if left.updated_at ~= right.updated_at then
      return left.updated_at < right.updated_at
    end
    if left.started_at ~= right.started_at then
      return left.started_at < right.started_at
    end
    return left.id < right.id
  end)
  return entries
end

local function publish()
  local payload = sorted_entries()
  for _, cb in pairs(M._subscribers) do
    cb(vim.deepcopy(payload))
  end
end

---@return parley.ProgressEntry[]
function M.list()
  return sorted_entries()
end

---@param entry parley.ProgressEntry
function M.upsert(entry)
  M._entries[entry.id] = vim.deepcopy(entry)
  publish()
end

---@param id string
function M.remove(id)
  M._entries[id] = nil
  publish()
end

function M.clear()
  M._entries = {}
  publish()
end

---@param cb fun(entries: parley.ProgressEntry[]): nil
---@return fun()
function M.subscribe(cb)
  M._next_subscriber_id = M._next_subscriber_id + 1
  local id = M._next_subscriber_id
  M._subscribers[id] = cb
  return function()
    M._subscribers[id] = nil
  end
end

return M
