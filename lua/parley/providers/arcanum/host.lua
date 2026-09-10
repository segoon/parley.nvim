--- Validate a configured HTTPS authority before it is combined with API paths.
local M = {}
--- @param host any
--- @return boolean
function M.valid(host)
  if type(host) ~= "string" or host == "" or host:find("[%s/@?#\\]") then
    return false
  end
  local name, port
  if host:sub(1, 1) == "[" then
    local address, suffix = host:match("^%[([^%]]+)%](.*)$")
    if not address or address:find("[^%x:]") or not address:find(":", 1, true) then
      return false
    end
    if address:find(":::", 1, true) then
      return false
    end
    if
      (address:sub(1, 1) == ":" and address:sub(1, 2) ~= "::")
      or (address:sub(-1) == ":" and address:sub(-2) ~= "::")
    then
      return false
    end
    local compressed = address:find("::", 1, true)
    if compressed and address:find("::", compressed + 2, true) then
      return false
    end
    if not compressed and (address:sub(1, 1) == ":" or address:sub(-1) == ":") then
      return false
    end
    local count = 0
    for part in address:gmatch("[^:]+") do
      if #part > 4 then
        return false
      end
      count = count + 1
    end
    if (compressed and count >= 8) or (not compressed and count ~= 8) then
      return false
    end
    if suffix ~= "" then
      port = suffix:match("^:(%d+)$")
      if not port then
        return false
      end
    end
  else
    name, port = host:match("^([^:]+):(%d+)$")
    name = name or host
    if name:find("[^%w%.%-]") or name:find("..", 1, true) or name:sub(1, 1) == "." then
      return false
    end
    for label in name:gmatch("[^.]+") do
      if #label > 63 or label:sub(1, 1) == "-" or label:sub(-1) == "-" then
        return false
      end
    end
    if #name > 253 then
      return false
    end
  end
  return not port or (tonumber(port) > 0 and tonumber(port) <= 65535)
end
return M
