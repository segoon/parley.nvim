--- parley.timestamp — shared timestamp formatting helpers.

local M = {}

--- @param timestamp string
--- @return string
local function normalize_timestamp(timestamp)
  return (timestamp:gsub("^(%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d)%.%d+(Z)$", "%1%2"))
end

--- @param seconds integer
--- @param unit string
--- @return string
local function pluralize(seconds, unit)
  if seconds == 1 then
    return string.format("1 %s ago", unit)
  end
  return string.format("%d %ss ago", seconds, unit)
end

--- @param epoch integer
--- @return integer
function M.utc_offset(epoch)
  return math.floor(os.difftime(epoch, os.time(os.date("!*t", epoch))))
end

---@param timestamp string
---@param hooks {
---  now: fun(): integer,
---  date: fun(fmt: string, time: integer): string,
---  strptime: fun(fmt: string, value: string): integer|nil,
---  utc_offset?: fun(epoch: integer): integer,
---}
---@return string
function M.format(timestamp, hooks)
  local normalized = normalize_timestamp(timestamp)
  local epoch = hooks.strptime("%Y-%m-%dT%H:%M:%SZ", normalized)
  if not epoch or epoch <= 0 then
    return timestamp
  end
  if normalized:sub(-1) == "Z" then
    local offset = hooks.utc_offset and hooks.utc_offset(epoch) or M.utc_offset(epoch)
    epoch = epoch + offset
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
