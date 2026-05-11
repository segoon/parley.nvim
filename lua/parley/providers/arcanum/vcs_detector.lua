--- parley.providers.arcanum.vcs_detector — Arc VCS detection.
---
--- Detects whether a buffer path lives inside an Arc (Arcadia VCS) repository
--- and extracts repo root, remote branch id, and the authenticated user login.
---
--- Arc commands used:
---   • arc root        — prints absolute repo root
---   • arc info --json — prints repository metadata including remote branch id
---                      and user_login
---
--- The user login is derived from the `user_login` field in `arc info --json`.
---
--- The `remote_url` field stores the Arc login using an internal
--- `arc://<login>` convention so provider detection can recover it later.
---
--- Testability:
---   • M._runner is the single I/O seam; replace it in tests to avoid real
---     arc invocations.

local await = require("parley.runtime.await")

local M = {}

-- ---------------------------------------------------------------------------
-- Default async runner
-- ---------------------------------------------------------------------------

--- Run a command asynchronously and return its result.
---
--- @type fun(cmd: string[], cwd: string): { code: integer, stdout: string, stderr: string }
M._runner = function(cmd, cwd)
  local result = await.system(cmd, { cwd = cwd, text = true })
  return {
    code = result.code,
    stdout = result.stdout or "",
    stderr = result.stderr or "",
  }
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Strip trailing whitespace (including newlines) from a string.
--- @param s string
--- @return string
local function trim(s)
  return (s:gsub("%s+$", ""))
end

--- Decode the JSON object returned by `arc info --json`.
--- @param json_output string
--- @return string|nil
local function decode_info(json_output)
  if type(json_output) ~= "string" or json_output == "" then
    return nil
  end

  local ok, data = pcall(vim.json.decode, json_output)
  if not ok or type(data) ~= "table" then
    return nil
  end

  return data
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Detect Arc VCS information for the file at `path`.
---
--- Must be called inside a plenary.async coroutine.  Returns nil when `path`
--- is not inside an Arc repository or when detection fails.
---
--- @param  path string  Buffer file path to probe
--- @return parley.VcsInfo|nil
function M.detect(path)
  local run = M._runner

  -- Derive the working directory from the file path.
  local cwd = vim.fn.fnamemodify(path, ":p:h")

  -- ── Step 1: is this path inside an arc repo? ─────────────────────────────
  local root_result = run({ "arc", "root" }, cwd)
  if root_result.code ~= 0 then
    return nil
  end
  local root = trim(root_result.stdout)
  if root == "" then
    return nil
  end

  -- ── Step 2: repo metadata from arc info --json ───────────────────────────
  local info_result = run({ "arc", "info", "--json" }, root)
  local branch = nil
  local login = nil
  if info_result.code == 0 then
    local info = decode_info(info_result.stdout or "")
    if info then
      if type(info.remote) == "string" and info.remote ~= "" then
        branch = info.remote
      end
      if type(info.user_login) == "string" and info.user_login ~= "" then
        login = info.user_login
      end
    end
  end

  --- @type parley.VcsInfo
  return {
    vcs = "arc",
    root = root,
    branch = branch,
    -- remote_url carries the login for use in detect_pr filtering;
    -- format: "arc://<login>" (not a real URL, just an internal convention)
    remote_url = login and ("arc://" .. login) or nil,
  }
end

return M
