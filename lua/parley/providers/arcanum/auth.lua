--- Arcanum credentials: explicit token values, explicit Arc path, then the default file.
local M = {}
--- @type fun(name: string): string|nil
M._getenv = os.getenv
--- @type fun(path: string): string|nil
M._read_file = function(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local content = file:read("*a")
  file:close()
  return content
end
--- @param value any
--- @return string|nil
local function value(raw)
  if type(raw) ~= "string" then
    return nil
  end
  local trimmed = raw:match("^%s*(.-)%s*$")
  return trimmed ~= "" and trimmed or nil
end
--- @return string|nil, string|nil, string|nil Token, safe error, non-secret source label.
function M.read_token()
  for _, source in ipairs({ "ARCANUM_TOKEN", "ARC_OAUTH_TOKEN" }) do
    local token = value(M._getenv(source))
    if token then
      return token, nil, source
    end
  end
  local path = value(M._getenv("ARC_TOKEN_PATH"))
  local source = path and "ARC_TOKEN_PATH" or "~/.arc/token"
  if not path then
    local home = value(M._getenv("HOME"))
    if home then
      path = home .. "/.arc/token"
    end
  end
  if path then
    local ok, content = pcall(M._read_file, path)
    local token = ok and value(content) or nil
    if token then
      return token, nil, source
    end
    if source == "ARC_TOKEN_PATH" then
      return nil, "ARC_TOKEN_PATH must name a readable, nonempty token file", source
    end
  end
  return nil,
    "no Arcanum token found: set ARCANUM_TOKEN, ARC_OAUTH_TOKEN, or ARC_TOKEN_PATH; default: ~/.arc/token",
    source
end
--- Local-file-only alias; does not perform HTTP.
--- @return string|nil, string|nil, string|nil
M.read_token_async = M.read_token
return M
