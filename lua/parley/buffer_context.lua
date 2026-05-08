--- parley.buffer_context — Buffer context detection.
---
--- Classifies a Neovim buffer as one of three kinds:
---   "regular"   — a standard file buffer whose path resides inside a VCS repo
---   "diffview"  — a buffer managed by diffview.nvim (detected via filetype/name)
---   "non_vcs"   — everything else: special buftype, no valid path, or no VCS root
---
--- Design notes:
---   • classify() is async and must be called inside a plenary.async coroutine
---     because _vcs_detect (defaulting to vcs.detect) yields while running git.
---   • M._get_buf_props is the buffer-property seam; replace it in tests to avoid
---     actual Neovim buffer access.
---   • M._vcs_detect is the VCS-detection seam; replace it in tests to avoid real
---     git invocations.
---   • "outside PR" (branch present but no open PR for it) is a provider-level
---     concern and is NOT classified here — only observable buffer properties
---     (filetype, name, buftype) are used, per PROJECT.md §5.2.

local vcs = require("parley.vcs")

local M = {}

-- ---------------------------------------------------------------------------
-- Type annotations
-- ---------------------------------------------------------------------------

--- @alias parley.BufferKind
--- | "regular"   -- standard file buffer inside a VCS repo
--- | "diffview"  -- diffview.nvim managed buffer
--- | "non_vcs"   -- no VCS repo detected; plugin fully inactive

--- Context for a single Neovim buffer.
---
--- @class parley.BufferContext
--- @field kind     parley.BufferKind
--- @field bufnr    integer
--- @field path     string|nil        Absolute file path; nil for non-file buffers
--- @field vcs_info parley.VcsInfo|nil  Populated only when kind == "regular"

-- ---------------------------------------------------------------------------
-- Known diffview.nvim filetypes (single source of truth)
-- ---------------------------------------------------------------------------

--- Filetypes set by diffview.nvim on its managed buffers.
--- Detection must not depend on diffview internals — only on observable
--- buffer properties — so this list is the canonical guard.
---
--- @type table<string, true>
local DIFFVIEW_FILETYPES = {
  DiffviewFiles = true,
  DiffviewDiff = true,
  DiffviewDiffFiles = true,
  DiffviewFileHistory = true,
  DiffviewFileHistoryPanel = true,
}

--- Buffer-name prefix used by diffview.nvim for all its special buffers.
local DIFFVIEW_NAME_PREFIX = "diffview://"

-- ---------------------------------------------------------------------------
-- Seams (replaceable in tests)
-- ---------------------------------------------------------------------------

--- Return the observable properties of buffer `bufnr`.
---
--- This is the single I/O seam for buffer inspection; replace it in tests
--- with a function that returns a plain table of fixed values.
---
--- @type fun(bufnr: integer): { filetype: string, name: string, buftype: string }
function M._get_buf_props(bufnr)
  return {
    filetype = vim.bo[bufnr].filetype,
    name = vim.api.nvim_buf_get_name(bufnr),
    buftype = vim.bo[bufnr].buftype,
  }
end

--- VCS-detection seam.  Defaults to the real (async) vcs.detect.
---
--- Replace in tests with a synchronous stub that returns a fixed VcsInfo
--- or nil without spawning any subprocesses.
---
--- @type fun(path: string): parley.VcsInfo|nil
M._vcs_detect = vcs.detect

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Classify buffer `bufnr` and return its context.
---
--- Must be called inside a plenary.async coroutine; the default
--- M._vcs_detect implementation yields while running git subprocesses.
---
--- @param  bufnr integer  Buffer number to classify
--- @return parley.BufferContext
function M.classify(bufnr)
  local props = M._get_buf_props(bufnr)

  -- ── Diffview detection ────────────────────────────────────────────────────
  -- Check filetype and buffer-name prefix before anything else; diffview
  -- buffers may carry unusual buftypes (e.g. "nofile") that would otherwise
  -- trigger the non-VCS path prematurely.
  if DIFFVIEW_FILETYPES[props.filetype] or vim.startswith(props.name, DIFFVIEW_NAME_PREFIX) then
    --- @type parley.BufferContext
    return {
      kind = "diffview",
      bufnr = bufnr,
      path = nil,
      vcs_info = nil,
    }
  end

  -- ── Special buftypes (terminal, nofile, prompt, quickfix, …) ─────────────
  -- These are not regular file buffers; no VCS detection makes sense.
  if props.buftype ~= "" then
    --- @type parley.BufferContext
    return {
      kind = "non_vcs",
      bufnr = bufnr,
      path = nil,
      vcs_info = nil,
    }
  end

  -- ── Unnamed / scratch buffers ─────────────────────────────────────────────
  local path = props.name
  if path == "" then
    --- @type parley.BufferContext
    return {
      kind = "non_vcs",
      bufnr = bufnr,
      path = nil,
      vcs_info = nil,
    }
  end

  -- ── Regular file: run VCS detection ──────────────────────────────────────
  local vcs_info = M._vcs_detect(path)
  if vcs_info == nil then
    --- @type parley.BufferContext
    return {
      kind = "non_vcs",
      bufnr = bufnr,
      path = path,
      vcs_info = nil,
    }
  end

  --- @type parley.BufferContext
  return {
    kind = "regular",
    bufnr = bufnr,
    path = path,
    vcs_info = vcs_info,
  }
end

return M
