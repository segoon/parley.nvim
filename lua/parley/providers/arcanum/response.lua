--- Pure Arcanum response validation and retry classification.
local M = {}
local transient_status = { [429] = true, [500] = true, [502] = true, [503] = true, [504] = true }
local transient_exit = {
  [5] = true,
  [6] = true,
  [7] = true,
  [18] = true,
  [28] = true,
  [35] = true,
  [52] = true,
  [55] = true,
  [56] = true,
  [92] = true,
}

--- @param status number
--- @return boolean
function M.retry_status(status)
  return transient_status[status] == true
end
--- @param exit number|nil
--- @return boolean
function M.retry_exit(exit)
  return transient_exit[exit] == true
end

--- @param response parley.HttpResponse
--- @return table|nil
function M.unwrap(response)
  if response.status == 204 and response.ok then
    return nil
  end
  if response.body == "" and response.ok then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, response.body)
  if not ok or type(decoded) ~= "table" or vim.islist(decoded) then
    error("Arcanum returned an invalid JSON response (HTTP " .. response.status .. ").", 0)
  end
  local messages = {}
  if decoded.errors ~= nil and decoded.errors ~= vim.NIL then
    if type(decoded.errors) ~= "table" or not vim.islist(decoded.errors) then
      error("Arcanum returned invalid API errors.", 0)
    end
    for _, entry in ipairs(decoded.errors) do
      messages[#messages + 1] = type(entry) == "table" and tostring(entry.message or entry.status or "API error")
        or tostring(entry)
    end
  end
  if #messages > 0 then
    error("Arcanum: " .. table.concat(messages, "; "), 0)
  end
  if not response.ok then
    error("Arcanum HTTP " .. response.status, 0)
  end
  if decoded.data == nil then
    error("Arcanum response is missing data.", 0)
  end
  if decoded.data == vim.NIL then
    return nil
  end
  if type(decoded.data) ~= "table" then
    error("Arcanum returned invalid response data.", 0)
  end
  return decoded.data
end

local months =
  { Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6, Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12 }

--- Convert IMF-fixdate directly to epoch seconds, independent of local timezone.
--- @param value string
--- @return number|nil
local function http_date(value)
  local day, month, year, hour, minute, second =
    value:match("^%a%a%a, (%d%d) (%a%a%a) (%d%d%d%d) (%d%d):(%d%d):(%d%d) GMT$")
  day, month, year = tonumber(day), months[month], tonumber(year)
  hour, minute, second = tonumber(hour), tonumber(minute), tonumber(second)
  if not day or not month or not year or hour > 23 or minute > 59 or second > 59 then
    return nil
  end
  local leap = year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
  local lengths = { 31, leap and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  if day < 1 or day > lengths[month] then
    return nil
  end
  local y = year - 1
  local days = 365 * (year - 1970) + math.floor(y / 4) - math.floor(y / 100) + math.floor(y / 400) - 477
  for m = 1, month - 1 do
    days = days + lengths[m]
  end
  return (days + day - 1) * 86400 + hour * 3600 + minute * 60 + second
end

--- @param headers table
--- @param wall_time number UTC epoch seconds.
--- @return number|nil Delay in milliseconds.
function M.retry_after(headers, wall_time)
  local delay
  if type(headers) ~= "table" then
    return nil
  end
  for key, value in pairs(headers) do
    local name = key
    if type(key) == "number" and type(value) == "string" then
      name, value = value:match("^([^:]+):%s*(.-)%s*$")
    end
    if type(name) == "string" and name:lower() == "retry-after" and type(value) == "string" then
      value = value:match("^%s*(.-)%s*$")
      local seconds = value:match("^%d+$") and tonumber(value) or nil
      if not seconds then
        local epoch = http_date(value)
        seconds = epoch and math.max(0, epoch - wall_time) or nil
      end
      if seconds and seconds < math.huge then
        delay = math.max(delay or 0, seconds * 1000)
      end
    end
  end
  return delay
end
return M
