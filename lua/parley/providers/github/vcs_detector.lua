--- parley.providers.github.vcs_detector — Git VCS detection.
---
--- Detects whether a buffer path lives inside a git repository and extracts
--- repo root, current branch, and remote URL.
---
--- This module was extracted from parley.vcs so that git detection is owned
--- by the GitHub provider, keeping parley.vcs as a provider-agnostic
--- dispatcher.
---
--- Testability:
---   • M._runner is the single I/O seam; replace it in tests to avoid real
---     git invocations.

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

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Detect git VCS information for the file at `path`.
---
--- Must be called inside a plenary.async coroutine.  Returns nil when `path`
--- is not inside a git repository or when detection fails.
---
--- @param  path string  Buffer file path to probe
--- @return parley.VcsInfo|nil
function M.detect(path)
  local run = M._runner

  -- Derive the working directory from the file path.
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
