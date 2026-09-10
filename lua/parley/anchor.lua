--- VCS-independent line anchoring against revision and local text.
--- File reads are asynchronous; hunk parsing and line remapping are pure.
--- Failed reads preserve stale approximations; deleted lines have no position.

local content = require("parley.local_content")

local M = {}
local semantics = require("parley.discussion")

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
--- @field stale          boolean      true when changed or unavailable.
--- @field error? string  Reason mapping is approximate.

-- ---------------------------------------------------------------------------
-- Injectable runner seam
-- ---------------------------------------------------------------------------

--- Read revision/local text and produce unified hunks. Injectable in tests.
--- @type fun(info: parley.VcsInfo, revision: string, file: string): string|nil, string|nil
M._diff = function(info, revision, file)
  local before, err = content.revision(info, revision, file)
  if before == nil then
    return nil, err
  end
  local after, local_err = content.read_local(info.root .. "/" .. file)
  if after == nil then
    return nil, local_err
  end
  if before:find("\0", 1, true) or after:find("\0", 1, true) then
    return nil, "binary content cannot be mapped"
  end
  return vim.diff(content.normalize(before), content.normalize(after), { ctxlen = 0 })
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
    if pr_line < h.old_start or (h.old_count == 0 and pr_line == h.old_start) then
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

--- @param line integer
--- @param err string
--- @return parley.anchor.Mapping
local function approximate(line, err)
  return { local_line = line, confidence = 0, stale = true, error = err }
end

--- Map a single line, retaining a marked approximation on read failure.
--- @param info parley.VcsInfo
--- @param revision string
--- @param file string
--- @param line integer
--- @return parley.anchor.Mapping
function M.map_line(info, revision, file, line)
  local ok, diff, err = pcall(M._diff, info, revision, file)
  if not ok then
    err, diff = tostring(diff), nil
  end
  if diff == nil then
    return approximate(line, err or "mapping unavailable")
  end
  return M.remap_line(line, M.parse_hunks(diff))
end

--- Map discussions against loaded buffers or working-tree files; one read per file.
--- @param info parley.VcsInfo
--- @param revision string
--- @param discussions parley.Discussion[]
--- @return table<string, parley.anchor.Mapping>
function M.map_discussions(info, revision, discussions)
  local by_file, mappings = {}, {}
  for _, disc in ipairs(discussions) do
    if semantics.projectable(disc) then
      by_file[disc.file] = by_file[disc.file] or {}
      table.insert(by_file[disc.file], disc)
    else
      local a = semantics.anchor(disc)
      mappings[disc.id] = {
        confidence = 0,
        stale = true,
        unavailable_reason = a.unavailable_reason
          or (a.kind == "file" and "Whole-file discussion" or "No line location"),
      }
    end
  end
  for file, entries in pairs(by_file) do
    local ok, diff, err = pcall(M._diff, info, revision, file)
    if not ok then
      err, diff = tostring(diff), nil
    end
    local hunks = diff and M.parse_hunks(diff) or {}
    for _, disc in ipairs(entries) do
      local mapping = diff and M.remap_line(disc.line, hunks) or approximate(disc.line, err or "mapping unavailable")
      if not diff and disc.anchor then
        mapping = { confidence = 0, stale = true, unavailable_reason = err or "Mapping unavailable" }
      end
      if disc.end_line and mapping.local_line then
        if diff then
          mapping.local_end_line = M.remap_line(disc.end_line, hunks).local_line
        else
          mapping.local_end_line = disc.end_line
        end
        for line = disc.line, disc.end_line do
          if M.remap_line(line, hunks).stale then
            mapping.stale, mapping.confidence = true, 0
          end
        end
      end
      mappings[disc.id] = mapping
    end
  end
  return mappings
end

return M
