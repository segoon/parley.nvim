--- Process-local Arcanum pacing, scoped by host and credential fingerprint.
local ui = require("parley.runtime.ui")
local M = {}
--- @type fun(): number
M._now = function()
  return (vim.uv or vim.loop).hrtime() / 1000000
end
--- @type fun(callback: fun(), delay: integer): table
M._defer = vim.defer_fn
--- @class parley.arcanum.Queue
--- @field interval number
--- @field last_start? number
--- @field cooldown number
--- @field entries table[]
--- @field timer? table
--- @type table<string, parley.arcanum.Queue>
local queues = {}

--- @param timer table|nil
function M.close_timer(timer)
  if not timer then
    return
  end
  if timer.stop then
    pcall(timer.stop, timer)
  end
  if timer.close then
    pcall(timer.close, timer)
  end
end

--- @param queue parley.arcanum.Queue
local function pump(queue)
  M.close_timer(queue.timer)
  queue.timer = nil
  local entry = queue.entries[1]
  if not entry then
    return
  end
  local now = M._now()
  local ready = math.max(entry.ready, queue.cooldown, queue.last_start and queue.last_start + queue.interval or now)
  if ready > now then
    queue.timer = M._defer(function()
      ui.dispatch(function()
        pump(queue)
      end)
    end, math.ceil(ready - now))
    return
  end
  table.remove(queue.entries, 1)
  entry.started = true
  queue.last_start = now
  entry.callback()
  pump(queue)
end

--- @param host string
--- @param token string
--- @param interval number
--- @return parley.arcanum.Queue
function M.scope(host, token, interval)
  local key = host:lower() .. ":" .. vim.fn.sha256(token)
  local queue = queues[key]
  if not queue then
    queue = { interval = interval, cooldown = 0, entries = {} }
    queues[key] = queue
  else
    queue.interval = math.max(queue.interval, interval)
  end
  return queue
end

--- @param queue parley.arcanum.Queue
--- @param ready number Earliest allowed monotonic start time.
--- @param callback fun()
--- @return parley.CancelHandle
function M.enqueue(queue, ready, callback)
  local entry = { ready = ready, callback = callback, started = false }
  queue.entries[#queue.entries + 1] = entry
  pump(queue)
  return {
    cancel = function()
      if entry.started then
        return
      end
      for i, candidate in ipairs(queue.entries) do
        if candidate == entry then
          table.remove(queue.entries, i)
          break
        end
      end
      entry.started = true
      pump(queue)
    end,
  }
end

--- @param queue parley.arcanum.Queue
--- @param until_ms number
function M.cooldown(queue, until_ms)
  queue.cooldown = math.max(queue.cooldown, until_ms)
  pump(queue)
end

--- Reset process-local state, primarily for deterministic test isolation.
function M.reset()
  for _, queue in pairs(queues) do
    M.close_timer(queue.timer)
  end
  queues = {}
end
return M
