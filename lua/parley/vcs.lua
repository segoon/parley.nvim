--- parley.vcs — VCS detection.
---
--- Detects whether a buffer path lives inside a recognised VCS repository
--- (git first) and extracts repo root, current branch, and remote URL.
---
--- Design notes:
---   • Uses vim.system (Neovim ≥ 0.10) wrapped with plenary.async so the
---     call yields the coroutine instead of blocking Neovim.
---   • detect() must be called inside a plenary.async coroutine.
---   • M._runner is the single I/O seam; replace it in tests to avoid real
---     git invocations.
---   • Only git is supported today; the interface is intentionally generic
---     so additional VCS backends can be added in later phases.

local async = require("plenary.async")

local M = {}

-- ---------------------------------------------------------------------------
-- Type annotations
-- ---------------------------------------------------------------------------

--- Information extracted from a VCS repository.
---
--- @class parley.VcsInfo
--- @field vcs        string      VCS type identifier, e.g. "git"
--- @field root       string      Absolute path to the repository root
--- @field branch     string|nil  Active branch name; nil when detached HEAD or unknown
--- @field remote_url string|nil  URL of the "origin" remote; nil when not configured

-- ---------------------------------------------------------------------------
-- Default async runner
-- ---------------------------------------------------------------------------

--- Run a command asynchronously and return its result.
---
--- Wrapped with plenary.async.wrap so it yields the current coroutine while
--- the subprocess runs, keeping Neovim responsive.
---
--- @type fun(cmd: string[], cwd: string): { code: integer, stdout: string, stderr: string }
M._runner = async.wrap(function(cmd, cwd, callback)
  vim.system(cmd, { cwd = cwd, text = true }, function(result)
    callback({
      code = result.code,
      stdout = result.stdout or "",
      stderr = result.stderr or "",
    })
  end)
end, 3)

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Strip trailing whitespace (including newlines) from a string.
---
--- @param s string
--- @return string
local function trim(s)
  return (s:gsub("%s+$", ""))
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Detect VCS information for the file at `path`.
---
--- Must be called inside a plenary.async coroutine.  Returns nil when `path`
--- is not inside a recognised VCS repository or when detection fails.
---
--- Currently only git is supported.  The returned `vcs` field is always
--- `"git"` when detection succeeds.
---
--- @param  path string  Buffer file path to probe
--- @return parley.VcsInfo|nil
function M.detect(path)
  local run = M._runner

  -- Derive the working directory from the file path.  For a regular file
  -- /a/b/c.lua this yields /a/b; for an empty string git will simply fail.
  local cwd = vim.fn.fnamemodify(path, ":p:h")

  -- ── Step 1: is this path inside a git repo? ──────────────────────────────
  local root_result = run({ "git", "rev-parse", "--show-toplevel" }, cwd)
  if root_result.code ~= 0 then
    return nil
  end
  local root = trim(root_result.stdout)

  -- ── Step 2: current branch ────────────────────────────────────────────────
  local branch_result = run({ "git", "rev-parse", "--abbrev-ref", "HEAD" }, root)
  local branch = nil
  if branch_result.code == 0 then
    local raw = trim(branch_result.stdout)
    -- "HEAD" is what git returns for a detached HEAD state — not a real branch.
    if raw ~= "HEAD" then
      branch = raw
    end
  end

  -- ── Step 3: origin remote URL ─────────────────────────────────────────────
  local remote_result = run({ "git", "remote", "get-url", "origin" }, root)
  local remote_url = nil
  if remote_result.code == 0 then
    remote_url = trim(remote_result.stdout)
  end

  --- @type parley.VcsInfo
  return {
    vcs = "git",
    root = root,
    branch = branch,
    remote_url = remote_url,
  }
end

return M
