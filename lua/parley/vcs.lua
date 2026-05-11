--- parley.vcs — VCS detection dispatcher.
---
--- Provides a generic `detect(path)` function that iterates registered VCS
--- detectors and returns the first match.  No built-in detectors are bundled
--- here; each provider module is responsible for registering its own detector
--- via `register_detector()` during `setup()`.
---
--- This design lets providers own their VCS probing logic while keeping the
--- buffer-classification pipeline (buffer_context.lua) provider-agnostic.
---
--- Design notes:
---   • detect() must be called inside a plenary.async coroutine because
---     detector functions typically yield while running subprocesses.
---   • Detectors are tried in registration order; first non-nil result wins.
---   • reset_detectors() is provided for test isolation.
---
--- Non-VCS helpers (check_sync_state, check_anchor_in_diff) remain here
--- because they are git-specific utilities shared across write-service flows.

local await = require("parley.runtime.await")
local anchor = require("parley.anchor")

local M = {}

-- ---------------------------------------------------------------------------
-- Type annotations
-- ---------------------------------------------------------------------------

--- Information extracted from a VCS repository.
---
--- @class parley.VcsInfo
--- @field vcs        string      VCS type identifier, e.g. "git" or "arc"
--- @field root       string      Absolute path to the repository root
--- @field branch     string|nil  Active branch name; for Arc this is the remote branch id from `arc info --json`
--- @field remote_url string|nil  URL of the "origin" remote or arc remote; nil when not configured

-- ---------------------------------------------------------------------------
-- Detector registry
-- ---------------------------------------------------------------------------

--- @type { name: string, fn: fun(path: string): parley.VcsInfo|nil }[]
local _detectors = {}

--- Register a VCS detector function.
---
--- Detectors are called in registration order with the buffer file path.
--- The first one that returns a non-nil VcsInfo wins.
---
--- @param name string   Human-readable identifier (e.g. "git", "arc")
--- @param fn   fun(path: string): parley.VcsInfo|nil
function M.register_detector(name, fn)
  assert(type(name) == "string" and name ~= "", "vcs.register_detector: name must be a non-empty string")
  assert(type(fn) == "function", "vcs.register_detector: fn must be a function")
  table.insert(_detectors, { name = name, fn = fn })
end

--- Remove all registered detectors.  Intended for test isolation.
function M.reset_detectors()
  _detectors = {}
end

--- Return a shallow copy of registered detectors in registration order.
--- @return { name: string, fn: fun(path: string): parley.VcsInfo|nil }[]
function M.registered_detectors()
  local copy = {}
  for i, d in ipairs(_detectors) do
    copy[i] = d
  end
  return copy
end

-- ---------------------------------------------------------------------------
-- Default async runner (shared by check_sync_state / check_anchor_in_diff)
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

--- Detect VCS information for the file at `path`.
---
--- Iterates registered detectors in order; returns the first non-nil result.
--- Returns nil when no detector matches or when no detectors are registered.
---
--- Must be called inside a plenary.async coroutine.
---
--- @param  path string  Buffer file path to probe
--- @return parley.VcsInfo|nil
function M.detect(path)
  for _, detector in ipairs(_detectors) do
    local info = detector.fn(path)
    if info ~= nil then
      return info
    end
  end
  return nil
end

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
--- @param head_sha string  PR head SHA received from the provider
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

return M
