--- parley.providers.arcanum.auth — Arcanum OAuth token resolution.
---
--- Resolution order (fast-to-slow, stops on first success):
---   1. Environment variable ARCANUM_TOKEN.
---   2. File ~/.arc/token (plain text, content trimmed).
---
--- Testability:
---   • M._getenv  — injectable os.getenv replacement.
---   • M._read_file — injectable synchronous file reader.

local M = {}

-- ---------------------------------------------------------------------------
-- Injectable seams
-- ---------------------------------------------------------------------------

--- @type fun(name: string): string|nil
M._getenv = os.getenv

--- @type fun(path: string): string|nil
M._read_file = function(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local content = f:read("*a")
  f:close()
  return content
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Strip leading and trailing whitespace from a string.
--- @param s string
--- @return string
local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Return the path to the arc token file.
--- Follows $HOME/.arc/token.
--- @return string
local function token_path()
  local home = M._getenv("HOME") or ""
  return home .. "/.arc/token"
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Read the Arcanum OAuth token.
---
--- Returns the token string on success, or nil + error message on failure.
---
--- @return string|nil, string|nil  token, err
function M.read_token()
  -- 1. Environment variable
  local env_token = M._getenv("ARCANUM_TOKEN")
  if type(env_token) == "string" and env_token ~= "" then
    return env_token, nil
  end

  -- 2. ~/.arc/token file
  local path = token_path()
  local content = M._read_file(path)
  if type(content) == "string" then
    local trimmed = trim(content)
    if trimmed ~= "" then
      return trimmed, nil
    end
  end

  return nil, "no Arcanum token found: set ARCANUM_TOKEN env var or write token to " .. token_path()
end

--- Async-compatible alias (reads token synchronously; kept for interface parity
--- with github auth which has read_token_async).
--- @return string|nil, string|nil  token, err
M.read_token_async = M.read_token

return M
