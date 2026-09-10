--- Deterministic monotonic clock and cancellable timers for transport tests.
local M = {}
--- @return table
function M.new()
  local clock = { time = 0, timers = {} }
  clock.now = function()
    return clock.time
  end
  clock.defer = function(callback, delay)
    local timer = { at = clock.time + delay, callback = callback, closed = false }
    timer.stop = function()
      timer.closed = true
    end
    timer.close = timer.stop
    clock.timers[#clock.timers + 1] = timer
    return timer
  end
  clock.advance = function(ms)
    local target = clock.time + ms
    while true do
      local next_timer
      for _, timer in ipairs(clock.timers) do
        if not timer.closed and timer.at <= target and (not next_timer or timer.at < next_timer.at) then
          next_timer = timer
        end
      end
      if not next_timer then
        break
      end
      clock.time = next_timer.at
      next_timer.closed = true
      next_timer.callback()
    end
    clock.time = target
  end
  return clock
end
return M
