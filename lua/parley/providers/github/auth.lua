--- parley.providers.github.auth — GitHub authentication.
---
--- Resolves a GitHub token for a given host using gh's official credential
--- resolution order:
---
---   1. Environment variables (host-class-dependent, see below).
---   2. oauth_token field in ~/.config/gh/hosts.yml (plain-text storage).
---
--- Host classes and their env vars (in priority order):
---   github.com  OR  *.ghe.com  →  GH_TOKEN, GITHUB_TOKEN
---   any other FQDN (GHES)      →  GH_ENTERPRISE_TOKEN, GITHUB_ENTERPRISE_TOKEN
---
--- Config dir for hosts.yml follows gh's own precedence:
---   $GH_CONFIG_DIR  →  $XDG_CONFIG_HOME/gh  →  $HOME/.config/gh
---
--- Keyring-backed tokens are out of scope; callers that need a last-resort
--- fallback may shell out to `gh auth token --hostname <host>`.
---
--- Testability:
---   Set M._read_file to a fun(path)->string|nil fake before calling any
---   function; restore to nil in after_each.
---   Set M._getenv to a fun(name)->string|nil fake to control env vars.

local M = {}
local runtime_fs = require("parley.runtime.fs")

-- ---------------------------------------------------------------------------
-- Type annotations
-- ---------------------------------------------------------------------------

--- @class parley.github.AuthResult
--- @field token string   The resolved token
--- @field source string  "env" or "hosts.yml"

-- ---------------------------------------------------------------------------
-- Injectable seams (for testing)
-- ---------------------------------------------------------------------------

--- Override file reading in tests.  nil = use real io.open.
--- @type fun(path: string): string|nil
M._read_file = nil

--- Override env-var lookup in tests.  nil = use real os.getenv.
--- @type fun(name: string): string|nil
M._getenv = nil

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Resolve an environment variable through the active seam.
---
--- @param name string
--- @return string|nil
local function getenv(name)
  if M._getenv then
    return M._getenv(name)
  end
  return os.getenv(name)
end

--- Read the entire contents of a file as a string through the active seam.
---
--- @param path string
--- @return string|nil
local function read_file(path)
  if M._read_file then
    return M._read_file(path)
  end
  return runtime_fs.read_file_sync(path)
end

--- @param path string
--- @return string|nil
local function read_file_async(path)
  if M._read_file then
    return M._read_file(path)
  end
  return runtime_fs.read_file(path)
end

--- Return true when the host belongs to the github.com / *.ghe.com class
--- that uses GH_TOKEN / GITHUB_TOKEN.
---
--- Per gh docs: "an authentication token that will be used when a command
--- targets either github.com or a subdomain of ghe.com."
---
--- @param host string  e.g. "github.com", "tenant.ghe.com", "ghe.mycompany.com"
--- @return boolean
local function is_dotcom_class(host)
  if host == "github.com" then
    return true
  end
  -- *.ghe.com — exactly one subdomain label before ".ghe.com"
  if host:sub(-#".ghe.com") == ".ghe.com" then
    return true
  end
  return false
end

--- Look up a token from environment variables for the given host.
---
--- @param host string
--- @return string|nil
local function token_from_env(host)
  if is_dotcom_class(host) then
    return getenv("GH_TOKEN") or getenv("GITHUB_TOKEN")
  else
    return getenv("GH_ENTERPRISE_TOKEN") or getenv("GITHUB_ENTERPRISE_TOKEN")
  end
end

--- Parse `content` (the full text of hosts.yml) and return the oauth_token
--- for `host`, or nil + an error message.
---
--- Parsing strategy: line scanner state machine.
---   1. Find a zero-indented line matching exactly "<host>:" (optional trailing
---      whitespace).
---   2. Inside that block scan indented lines for "oauth_token: <value>".
---   3. Stop when a new zero-indented non-blank line is encountered (next host
---      block begins).
---
--- This is sufficient for the predictable YAML written by the gh CLI.
---
--- @param content string   Full file content
--- @param host    string   FQDN to look up
--- @return string|nil token
--- @return string|nil error
local function parse_hosts_yaml(content, host)
  local host_pattern = "^" .. host:gsub("%.", "%%.") .. "%s*:$"
  local in_host_block = false

  for line in (content .. "\n"):gmatch("([^\n]*)\n") do
    if in_host_block then
      -- A zero-indented non-blank line signals the start of the next host block.
      if line:match("^[^%s]") and line ~= "" then
        break
      end
      -- Look for the oauth_token key inside this host's indented block.
      local raw = line:match("^%s+oauth_token:%s*(.*)")
      if raw then
        local token = raw:match("^%s*(.-)%s*$")
        if token and token ~= "" then
          return token, nil
        end
      end
    else
      if line:match(host_pattern) then
        in_host_block = true
      end
    end
  end

  if in_host_block then
    return nil, string.format("parley.github.auth: no oauth_token found for host '%s' in hosts.yml", host)
  end
  return nil, string.format("parley.github.auth: host '%s' not found in hosts.yml", host)
end

--- Look up a token from the gh hosts.yml config file.
---
--- @param host string
--- @return string|nil token
--- @return string|nil error
local function token_from_file(host)
  local path = M.token_path()
  local content = read_file(path)
  if not content then
    return nil, string.format("parley.github.auth: cannot read '%s'", path)
  end
  return parse_hosts_yaml(content, host)
end

--- @param host string
--- @return string|nil token
--- @return string|nil error
local function token_from_file_async(host)
  local path = M.token_path()
  local content = read_file_async(path)
  if not content then
    return nil, string.format("parley.github.auth: cannot read '%s'", path)
  end
  return parse_hosts_yaml(content, host)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Return the gh config directory, following gh's own precedence:
---   $GH_CONFIG_DIR  →  $XDG_CONFIG_HOME/gh  →  $HOME/.config/gh
---
--- @return string
function M.config_dir()
  local explicit = getenv("GH_CONFIG_DIR")
  if explicit and explicit ~= "" then
    return explicit
  end

  local xdg = getenv("XDG_CONFIG_HOME")
  if xdg and xdg ~= "" then
    return xdg .. "/gh"
  end

  local home = getenv("HOME") or ""
  return home .. "/.config/gh"
end

--- Return the full path to gh's hosts.yml file.
---
--- @return string
function M.token_path()
  return M.config_dir() .. "/hosts.yml"
end

--- Resolve the GitHub token for `host`.
---
--- Resolution order:
---   1. Environment variable (GH_TOKEN / GITHUB_TOKEN for github.com + *.ghe.com;
---      GH_ENTERPRISE_TOKEN / GITHUB_ENTERPRISE_TOKEN for all other hosts).
---   2. oauth_token field in hosts.yml.
---
--- @param host string  FQDN of the GitHub host (e.g. "github.com", "ghe.corp.com")
--- @return string|nil token
--- @return string|nil error
function M.read_token(host)
  assert(type(host) == "string" and host ~= "", "parley.github.auth.read_token: host must be a non-empty string")

  local env_token = token_from_env(host)
  if env_token and env_token ~= "" then
    return env_token, nil
  end

  return token_from_file(host)
end

--- Resolve the GitHub token for `host` without blocking the main loop.
---
--- Must be called inside a plenary.async coroutine when using the real filesystem.
---
--- @param host string
--- @return string|nil token
--- @return string|nil error
function M.read_token_async(host)
  assert(type(host) == "string" and host ~= "", "parley.github.auth.read_token_async: host must be a non-empty string")

  local env_token = token_from_env(host)
  if env_token and env_token ~= "" then
    return env_token, nil
  end

  return token_from_file_async(host)
end

return M
