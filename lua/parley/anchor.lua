--- parley.anchor — Line anchoring engine.
---
--- Maps (file, line-in-PR-diff-space) to (line-in-local-buffer) by running
--- `git diff --unified=0 {base_commit} -- {file}` and walking the resulting
--- hunks.
---
--- Design notes:
---   • parse_hunks and remap_line are pure functions with no I/O — unit-testable
---     without any subprocess.
---   • map_line and map_discussions are async; they must be called from within
---     a plenary.async coroutine context.
---   • map_discussions batches by file: one git call per unique file path.
---   • M._runner is the single I/O seam; replace it in tests to avoid real git.
---
--- Staleness semantics:
---   • stale = false, confidence = 1.0  — line maps exactly; no local change
---     affects it.
---   • stale = true,  confidence = 0.0  — the anchored line was modified or
---     deleted locally.
---   • local_line = nil                 — the anchored line was deleted
---     entirely (pure-deletion hunk, new_count = 0); there is no sensible
---     local position.

local await = require("parley.runtime.await")

local M = {}

-- ---------------------------------------------------------------------------
-- Type annotations
-- ---------------------------------------------------------------------------

--- A parsed unified-diff hunk.
--- @class parley.anchor.Hunk
--- @field old_start integer  First line of the old (PR head) region (1-indexed)
--- @field old_count integer  Number of lines in the old region (0 = pure insertion)
--- @field new_start integer  First line of the new (local) region (1-indexed)
--- @field new_count integer  Number of lines in the new region (0 = pure deletion)

--- The result of mapping a single PR-diff-space line to a local buffer line.
--- @class parley.anchor.Mapping
--- @field local_line     integer|nil  Corresponding line in local buffer; nil when
---                                    the anchored lines were deleted entirely.
--- @field local_end_line integer|nil  End of the mapped local range for multi-line
---                                    anchors; nil for single-line anchors or when
---                                    the end line was deleted entirely.
--- @field confidence     number       1.0 = exact mapping; 0.0 = stale/deleted.
--- @field stale          boolean      true when pr_line was inside a changed hunk.

-- ---------------------------------------------------------------------------
-- Injectable runner seam
-- ---------------------------------------------------------------------------

--- Run a command and return { code, stdout, stderr }.
--- Replace in tests to avoid real git invocations.
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
-- Pure helpers
-- ---------------------------------------------------------------------------

--- Parse unified diff output into a list of hunks sorted by old_start.
---
--- Only `@@ … @@` header lines are consumed; all other lines (file headers,
--- `+`/`-` content lines) are ignored.
---
--- Unified diff hunk header format:
---   @@ -old_start[,old_count] +new_start[,new_count] @@
--- `old_count` and `new_count` each default to 1 when omitted (git convention).
---
--- @param diff_output string  Raw output of `git diff --unified=0`
--- @return parley.anchor.Hunk[]
function M.parse_hunks(diff_output)
  local hunks = {}
  for line in (diff_output .. "\n"):gmatch("([^\n]*)\n") do
    -- Match: @@ -<old_start>[,<old_count>] +<new_start>[,<new_count>] @@
    local os, oc, ns, nc = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
    if os then
      table.insert(hunks, {
        old_start = tonumber(os),
        old_count = (oc ~= "" and tonumber(oc)) or 1,
        new_start = tonumber(ns),
        new_count = (nc ~= "" and tonumber(nc)) or 1,
      })
    end
  end
  return hunks
end

--- Return true iff `line` falls within any hunk's new-side (RIGHT) region.
---
--- The new-side region of a hunk is [new_start, new_start + new_count).
--- Pure deletions (new_count = 0) have an empty region and are never valid
--- comment targets on the RIGHT side.
---
--- Used on the write path to validate that a cursor line is actually part of
--- the PR diff before sending it to the GitHub API.
---
--- @param line  integer               Line number in the file at HEAD (1-indexed)
--- @param hunks parley.anchor.Hunk[]
--- @return boolean
function M.is_line_in_hunk(line, hunks)
  for _, h in ipairs(hunks) do
    if h.new_count > 0 and line >= h.new_start and line < h.new_start + h.new_count then
      return true
    end
  end
  return false
end

--- Remap a single PR-diff-space line through a list of hunks.
---
--- Hunks must be sorted by old_start in ascending order (parse_hunks guarantees
--- this because git emits hunks in file order).
---
--- Algorithm:
---   Walk hunks in order, accumulating an offset (new_count - old_count) after
---   each hunk.  For each hunk:
---     • If pr_line < hunk.old_start → line is before this hunk; apply offset.
---     • If pr_line is inside [old_start, old_start + old_count) → stale:
---         - new_count = 0 (pure deletion): local_line = nil
---         - otherwise:                     local_line = new_start
---     • Otherwise accumulate offset and continue.
---   After all hunks, apply total accumulated offset.
---
--- @param pr_line integer           Line number in PR-diff space (1-indexed)
--- @param hunks   parley.anchor.Hunk[]
--- @return parley.anchor.Mapping
function M.remap_line(pr_line, hunks)
  local offset = 0

  for _, h in ipairs(hunks) do
    if pr_line < h.old_start then
      -- Line is before this hunk; no further offset needed.
      return {
        local_line = pr_line + offset,
        confidence = 1.0,
        stale = false,
      }
    end

    -- Is pr_line inside this hunk's old region?
    -- The region is [old_start, old_start + old_count).
    -- When old_count = 0 (pure insertion) the range is empty, so this branch
    -- is never taken for pure insertions.
    if pr_line < h.old_start + h.old_count then
      if h.new_count == 0 then
        -- Pure deletion: the lines are gone; no local position exists.
        return { local_line = nil, confidence = 0.0, stale = true }
      else
        -- Replacement: map to the start of the new region.
        return { local_line = h.new_start, confidence = 0.0, stale = true }
      end
    end

    -- Line is past this hunk; accumulate its net offset.
    offset = offset + (h.new_count - h.old_count)
  end

  -- Line is after all hunks; apply total offset.
  return {
    local_line = pr_line + offset,
    confidence = 1.0,
    stale = false,
  }
end

-- ---------------------------------------------------------------------------
-- Async public API
-- ---------------------------------------------------------------------------

--- Map a single anchor from PR-diff space to local buffer space.
---
--- Must be called from within a plenary.async coroutine.
---
--- @param repo_root   string   Absolute path to the git repository root
--- @param base_commit string   PR head commit SHA
--- @param file        string   Repo-relative file path
--- @param pr_line     integer  Line number in PR-diff space
--- @return parley.anchor.Mapping
function M.map_line(repo_root, base_commit, file, pr_line)
  local result = M._runner({ "git", "diff", "--unified=0", base_commit, "--", file }, repo_root)

  if result.code ~= 0 or result.stdout == "" then
    -- No diff or git error: treat line as unchanged.
    return { local_line = pr_line, confidence = 1.0, stale = false }
  end

  local hunks = M.parse_hunks(result.stdout)
  return M.remap_line(pr_line, hunks)
end

--- Map all discussion anchors to local buffer positions.
---
--- Batches git calls by file: one `git diff` invocation per unique file path
--- referenced across all discussions.
---
--- Must be called from within a plenary.async coroutine.
---
--- @param repo_root   string               Absolute path to the git repo root
--- @param base_commit string               PR head commit SHA
--- @param discussions parley.Discussion[]
--- @return table<string, parley.anchor.Mapping>  Keyed by discussion.id
function M.map_discussions(repo_root, base_commit, discussions)
  if #discussions == 0 then
    return {}
  end

  -- Build a set of unique file paths and collect discussions per file.
  --- @type table<string, parley.Discussion[]>
  local by_file = {}
  for _, disc in ipairs(discussions) do
    if not by_file[disc.file] then
      by_file[disc.file] = {}
    end
    table.insert(by_file[disc.file], disc)
  end

  -- For each unique file, run git diff once and remap all its discussions.
  --- @type table<string, parley.anchor.Mapping>
  local mappings = {}

  for file, file_discussions in pairs(by_file) do
    local result = M._runner({ "git", "diff", "--unified=0", base_commit, "--", file }, repo_root)

    local hunks = {}
    if result.code == 0 and result.stdout ~= "" then
      hunks = M.parse_hunks(result.stdout)
    end

    for _, disc in ipairs(file_discussions) do
      local mapping = M.remap_line(disc.line, hunks)
      if disc.end_line then
        mapping.local_end_line = M.remap_line(disc.end_line, hunks).local_line
      end
      mappings[disc.id] = mapping
    end
  end

  return mappings
end

return M
