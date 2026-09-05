--- Poll already-loaded visible reviews without accumulating background work.
local reviews = require("parley.repositories.review")
local read = require("parley.services.read")
local M = {}
local generation, interval, focused, timer = 0, 0, true, nil

--- @class parley.PeriodicCandidate
--- @field bufnr integer
--- @field key string

--- @param callback fun()
--- @param delay integer
--- @return table
M._defer = function(callback, delay)
  local handle = (vim.uv or vim.loop).new_timer()
  handle:start(delay, 0, vim.schedule_wrap(callback))
  return handle
end
--- @type fun(bufnr: integer, opts: table, callback: function)
M._refresh = function(bufnr, opts, callback)
  return read.refresh_async(bufnr, opts, callback)
end

--- @return integer[]
local function visible_sources()
  local result, seen = {}, {}
  local window = require("parley.discussion_window")
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = window.resolve_source_bufnr(vim.api.nvim_win_get_buf(win))
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) and not seen[buf] then
      seen[buf] = true
      result[#result + 1] = buf
    end
  end
  table.sort(result)
  return result
end

--- @param item parley.PeriodicCandidate
--- @return boolean
M._eligible = function(item)
  if not vim.tbl_contains(visible_sources(), item.bufnr) then
    return false
  end
  local state, activity = reviews.get(item.bufnr), reviews.activity(item.bufnr)
  if not state or not state.review or not activity or activity.key ~= item.key or activity.in_flight then
    return false
  end
  local write = require("parley.services.write")
  for _, buf in ipairs(activity.buffers) do
    if read.is_refreshing(buf) or write.is_busy(buf) then
      return false
    end
  end
  return true
end

--- @return parley.PeriodicCandidate[]
M._candidates = function()
  local items, seen = {}, {}
  for _, buf in ipairs(visible_sources()) do
    local activity = reviews.activity(buf)
    if activity and not seen[activity.key] then
      local item = { bufnr = buf, key = activity.key }
      if M._eligible(item) then
        seen[activity.key] = true
        items[#items + 1] = item
      end
    end
  end
  return items
end

local function clear_timer()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
end

--- @param value any
function M.validate(value)
  assert(
    type(value) == "number" and value >= 0 and value % 1 == 0 and value <= math.floor(9007199254740991 / 1000),
    "parley: refresh_interval must be a nonnegative integer number of seconds within timer range"
  )
end

--- @param token integer
local function arm(token)
  if token ~= generation or interval == 0 or not focused then
    return
  end
  timer = M._defer(function()
    if token ~= generation then
      return
    end
    clear_timer()
    local ok, items = pcall(M._candidates)
    if not ok then
      arm(token)
      return
    end
    local index = 0
    local function advance()
      if token ~= generation or not focused then
        return
      end
      index = index + 1
      local item = items[index]
      while item do
        local valid, eligible = pcall(M._eligible, item)
        if valid and eligible then
          break
        end
        index = index + 1
        item = items[index]
      end
      if not item then
        arm(token)
        return
      end
      local completed = false
      local function finish()
        if completed then
          return
        end
        completed = true
        advance()
      end
      local started = pcall(M._refresh, item.bufnr, {
        force = true,
        background = true,
        notify_errors = false,
        expected_key = item.key,
      }, finish)
      if not started then
        finish()
      end
    end
    advance()
  end, interval * 1000)
end

--- Stop future polling; already-started reads retain their own lifecycle.
function M.stop()
  interval = 0
  generation = generation + 1
  clear_timer()
end
--- @param value integer
function M.setup(value)
  M.validate(value)
  M.stop()
  interval = value
  arm(generation)
end
--- @param value boolean
function M.focus(value)
  if focused == value then
    return
  end
  focused = value
  generation = generation + 1
  clear_timer()
  if value then
    arm(generation)
  end
end
return M
