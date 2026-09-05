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
--- Revision reads and write validation dispatch through explicit VCS adapters.

local await = require("parley.runtime.await")
local adapters = require("parley.vcs.adapters")

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

--- Register an adapter for revision reads and local validation.
--- Register custom adapters after setup(); duplicate names are rejected.
--- @param name string
--- @param adapter parley.VcsAdapter
function M.register_adapter(name, adapter)
  adapters.register(name, adapter)
end

--- Remove all adapters. Does not change detector registrations.
function M.reset_adapters()
  adapters.reset()
end

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
-- Default async runner (shared by check_sync_state / read_diff)
-- ---------------------------------------------------------------------------

--- Run a command asynchronously and return its result.
---
--- @type fun(cmd: string[], cwd: string): { code: integer, stdout: string, stderr: string }
M._runner = function(cmd, cwd)
  local result = await.system(cmd, { cwd = cwd, text = true, timeout = 10000 })
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

--- Read a file at an immutable review revision.
--- @param info parley.VcsInfo
--- @param revision string
--- @param path string
--- @return string|nil, string|nil
function M.read_file(info, revision, path)
  local adapter, err = adapters.get(info)
  if not adapter then
    return nil, err
  end
  if type(revision) ~= "string" or revision == "" or revision:sub(1, 1) == "-" then
    return nil, "review revision is unavailable"
  end
  local result = M._runner(adapter.show(revision, path), info.root)
  if result.code ~= 0 then
    return nil, result.stderr or "cannot read revision content"
  end
  return result.stdout or ""
end

--- Require a clean file and local HEAD equal to the shared review revision.
--- @param info parley.VcsInfo
--- @param rel_path string
--- @param head_sha string
--- @return {ok: boolean, err?: string}
function M.check_sync_state(info, rel_path, head_sha)
  local adapter, err = adapters.get(info)
  if not adapter then
    return { ok = false, err = "Cannot comment: " .. err }
  end
  if type(head_sha) ~= "string" or head_sha == "" then
    return { ok = false, err = "Cannot comment: review revision is unavailable. Refresh the review and retry." }
  end
  local result = M._runner(adapter.head(), info.root)
  if result.code ~= 0 then
    return { ok = false, err = "Cannot comment: failed to read local HEAD (" .. (result.stderr or "") .. ")" }
  end
  if trim(result.stdout or "") ~= head_sha then
    return {
      ok = false,
      err = "Cannot comment: local checkout differs from the review revision. "
        .. "Synchronize the checkout and review, then retry.",
    }
  end
  result = M._runner(adapter.status(rel_path), info.root)
  if result.code ~= 0 then
    return { ok = false, err = "Cannot comment: failed to check file status (" .. (result.stderr or "") .. ")" }
  end
  local dirty, status_err = adapter.dirty(result.stdout or "")
  if dirty == nil then
    return { ok = false, err = "Cannot comment: " .. status_err }
  end
  if dirty then
    return {
      ok = false,
      err = "Cannot comment: '" .. rel_path .. "' has uncommitted changes. Commit or stash them and retry.",
    }
  end
  return { ok = true }
end

--- Read a review diff through the registered VCS adapter.
--- @param info parley.VcsInfo
--- @param base_branch string
--- @param rel_path string
--- @param head_sha string
--- @return string|nil, string|nil
function M.read_diff(info, base_branch, rel_path, head_sha)
  local adapter, err = adapters.get(info)
  if not adapter then
    return nil, err
  end
  if type(base_branch) ~= "string" or base_branch == "" or base_branch:sub(1, 1) == "-" then
    return nil, "review base is unavailable."
  end
  if type(head_sha) ~= "string" or head_sha == "" or head_sha:sub(1, 1) == "-" then
    return nil, "review revision is unavailable"
  end
  local result = M._runner(adapter.diff(base_branch, head_sha, rel_path), info.root)
  if result.code ~= 0 then
    return nil, "failed to read review diff (" .. (result.stderr or "") .. ")"
  end
  return result.stdout
end

return M
