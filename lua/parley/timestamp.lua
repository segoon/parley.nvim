--- parley.timestamp — shared timestamp formatting helpers.

local M = {}

--- @param seconds integer
--- @param unit string
--- @return string
local function pluralize(seconds, unit)
  if seconds == 1 then
    return string.format("1 %s ago", unit)
  end
  return string.format("%d %ss ago", seconds, unit)
end

---@param timestamp string
---@param hooks { now: fun(): integer, date: fun(fmt: string, time: integer): string, strptime: fun(fmt: string, value: string): integer|nil }
---@return string
function M.format(timestamp, hooks)
  local epoch = hooks.strptime("%Y-%m-%dT%H:%M:%SZ", timestamp)
  if not epoch then
    return timestamp
  end

  local delta = math.max(0, hooks.now() - epoch)
  local ago
  if delta < 3600 then
    ago = pluralize(math.max(1, math.floor(delta / 60)), "min")
  elseif delta < 86400 then
    ago = pluralize(math.floor(delta / 3600), "hour")
  else
    ago = pluralize(math.floor(delta / 86400), "day")
  end

  return string.format("%s (%s)", hooks.date("%Y-%m-%d %H:%M:%S (%Z)", epoch), ago)
end

return M
