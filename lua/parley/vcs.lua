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

local await = require("parley.runtime.await")
local anchor = require("parley.anchor")

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
---
--- @param s string
--- @return string
local function trim(s)
  return (s:gsub("%s+$", ""))
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Check that the local repo is in a state suitable for posting a new comment.
---
--- Two checks are performed in order; the first failure short-circuits:
---   1. Local HEAD matches the PR `head_sha` — no unpushed commits.
---   2. The file at `rel_path` has no uncommitted changes.
---
--- Must be called inside a plenary.async coroutine.
---
--- @param root     string  Absolute repo root (cwd for git commands)
--- @param rel_path string  Repo-relative path of the file being commented on
--- @param head_sha string  PR head SHA received from GitHub
--- @return { ok: boolean, err?: string }
function M.check_sync_state(root, rel_path, head_sha)
  local run = M._runner

  -- ── 1. Unpushed commits ───────────────────────────────────────────────────
  local head_result = run({ "git", "rev-parse", "HEAD" }, root)
  if head_result.code ~= 0 then
    return { ok = false, err = "Cannot comment: failed to read local HEAD (" .. (head_result.stderr or "") .. ")" }
  end
  local local_sha = trim(head_result.stdout)
  if local_sha ~= head_sha then
    return {
      ok = false,
      err = "Cannot comment: local branch has commits not yet pushed to the remote. Push first and retry.",
    }
  end

  -- ── 2. Uncommitted changes in the file ───────────────────────────────────
  local status_result = run({ "git", "status", "--porcelain", "--", rel_path }, root)
  if status_result.code ~= 0 then
    return {
      ok = false,
      err = "Cannot comment: failed to check file status (" .. (status_result.stderr or "") .. ")",
    }
  end
  if (status_result.stdout or "") ~= "" then
    return {
      ok = false,
      err = "Cannot comment: '" .. rel_path .. "' has uncommitted changes. Commit or stash them and retry.",
    }
  end

  return { ok = true }
end

--- Check that the anchor lines fall within the PR diff for a given file.
---
--- Runs `git diff --unified=0 origin/{base_branch}...HEAD -- {rel_path}` to
--- obtain the diff between the PR base and the current HEAD, then validates
--- that every line in the anchor appears within a changed hunk on the new
--- (RIGHT) side.
---
--- Must be called inside a plenary.async coroutine.
---
--- @param root        string        Absolute repo root (cwd for git commands)
--- @param base_branch string        PR base branch name (e.g. "main")
--- @param rel_path    string        Repo-relative path of the file being commented on
--- @param anch        parley.Anchor
--- @return { ok: boolean, err?: string }
function M.check_anchor_in_diff(root, base_branch, rel_path, anch)
  local run = M._runner
  local base_ref = "origin/" .. base_branch

  local result = run({ "git", "diff", "--unified=0", base_ref .. "...HEAD", "--", rel_path }, root)

  if result.code ~= 0 then
    -- Git error (e.g. unknown base branch): allow the comment through rather
    -- than silently blocking the user.
    return { ok = true }
  end

  if result.stdout == "" then
    -- No diff output → file is unchanged in this PR.
    return {
      ok = false,
      err = "Cannot comment: '" .. rel_path .. "' has no changes in this PR. Only changed lines can be commented on.",
    }
  end

  local hunks = anchor.parse_hunks(result.stdout)

  local function line_err(line)
    return "Cannot comment: line "
      .. tostring(line)
      .. " is not part of the PR diff. Move the cursor to a changed line."
  end

  if not anchor.is_line_in_hunk(anch.start_line, hunks) then
    return { ok = false, err = line_err(anch.start_line) }
  end

  if anch.end_line and not anchor.is_line_in_hunk(anch.end_line, hunks) then
    return { ok = false, err = line_err(anch.end_line) }
  end

  return { ok = true }
end

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
