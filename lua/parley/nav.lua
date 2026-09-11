--- parley.nav — Navigation between commented lines.
---
--- Provides buf_next/buf_prev (within the current buffer) and
--- review_next/review_prev (across all files in the whole review).
---
--- Design notes:
---   • buf_next/buf_prev operate on the **current window's** cursor.
---   • Rows are deduplicated: multiple discussions on the same line produce
---     only one navigation stop for buffer-scoped navigation.
---   • Wrap-around is silent (consistent with built-in ]c diff navigation).
---   • When no marks/discussions exist a brief vim.notify is emitted and the
---     cursor is left unchanged.
---   • review_next/review_prev sort all discussions by (file, line) in
---     PR-diff space for a stable, deterministic order.
---   • Cross-file jumps use `vim.cmd("edit …")` to open the target file;
---     the cursor is then placed at the discussion's PR-diff-space line
---     (best approximation before the BufEnter refresh runs).

local M = {}

-- ---------------------------------------------------------------------------
-- Private helpers
-- ---------------------------------------------------------------------------

--- Return a deduplicated, ascending list of 0-indexed row numbers that have
--- at least one parley extmark in `bufnr`.
---
--- @param discussions parley.Discussion[]
--- @param mappings table<string, parley.anchor.Mapping>
--- @param filter 'unresolved'
--- @return integer[]
function M._mapped_rows(discussions, mappings, filter)
  discussions = require("parley.discussion").filter(discussions, filter)
  local seen = {}
  local rows = {}
  for _, discussion in ipairs(discussions) do
    local mapping = mappings[discussion.id]
    if mapping and mapping.local_line then
      seen[mapping.local_line - 1] = true
    end
  end
  for row in pairs(seen) do
    rows[#rows + 1] = row
  end
  table.sort(rows)
  return rows
end

--- @param bufnr integer
--- @param filter? 'unresolved'
--- @return integer[]
function M._unique_rows(bufnr, filter)
  if filter then
    local read_service = require("parley.services.read")
    local state = read_service.get_buffer_state(bufnr)
    if not state then
      return {}
    end
    return M._mapped_rows(
      read_service.list_discussions(bufnr, { scope = "file" }),
      state.mappings or state.all_mappings or {},
      filter
    )
  end
  local signs = require("parley.signs")
  local ns = signs._get_ns()
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})

  local seen = {}
  local rows = {}
  for _, mark in ipairs(marks) do
    local row = mark[2] -- 0-indexed
    if not seen[row] then
      seen[row] = true
      rows[#rows + 1] = row
    end
  end
  -- nvim_buf_get_extmarks returns marks sorted by position; rows are already
  -- in ascending order.
  return rows
end

--- Return all discussions for `bufnr`'s review, sorted by (file, line).
---
--- Returns nil when no review data is available for the buffer.
---
--- @param bufnr integer
--- @param filter? 'unresolved'
--- @return parley.Discussion[]|nil
function M._sorted_review_discussions(bufnr, filter)
  local read_service = require("parley.services.read")
  local all = read_service.list_discussions(bufnr, { scope = "all" })
  if not all or #all == 0 then
    return all -- empty table or nil
  end
  -- Stable sort by (file, line).
  local state = require("parley.repositories.review").get(bufnr)
  local mapped = state and state.all_mappings or {}
  local filtered = require("parley.discussion").filter(all, filter)
  local sorted = vim.tbl_filter(function(d)
    return require("parley.discussion").projectable(d) and not (mapped[d.id] and mapped[d.id].local_line == nil)
  end, vim.deepcopy(filtered))
  table.sort(sorted, function(a, b)
    if a.file ~= b.file then
      return a.file < b.file
    end
    return a.line < b.line
  end)
  return sorted
end

--- Move the cursor to `disc`'s `target_line`, switching files first if
--- `disc.file` differs from `ctx.rel_path`.
---
--- When `bufnr` is a diffview-aliased buffer, cross-file switches go through
--- diffview_integration.goto_file (diffview's own file-selection API)
--- instead of `vim.cmd("edit …")`, which would blow away diffview's layout.
---
--- @param bufnr integer            Resolved source buffer (post-float-resolve)
--- @param winid integer            Source window
--- @param original_bufnr integer   Buffer nav was invoked with (may be a float)
--- @param ctx table                context_repository snapshot for `bufnr`
--- @param vcs_root string
--- @param head_sha string|nil
--- @param disc parley.Discussion
--- @param target_line integer
local function goto_discussion(bufnr, winid, original_bufnr, ctx, vcs_root, head_sha, disc, target_line)
  local from_float = original_bufnr ~= bufnr
  if from_float then
    require("parley.discussion_window").close(bufnr)
  end

  if disc.file ~= ctx.rel_path and require("parley.buffer_context").is_diffview_buffer(bufnr) then
    local switched = require("parley.diffview_integration").goto_file(disc.file, target_line, head_sha)
    if not switched then
      vim.notify("Could not switch to " .. disc.file .. " in diffview", vim.log.levels.WARN)
      return
    end
    if from_float then
      local new_bufnr = vim.api.nvim_get_current_buf()
      local new_line = vim.api.nvim_win_get_cursor(0)[1]
      vim.schedule(function()
        require("parley.discussion_window").open_current_line(new_bufnr, { cursor_line = new_line })
      end)
    end
    return
  end

  vim.api.nvim_set_current_win(winid)
  if disc.file ~= ctx.rel_path then
    vim.cmd("edit " .. vim.fn.fnameescape(vcs_root .. "/" .. disc.file))
  end
  local target_buf = vim.api.nvim_win_get_buf(winid)
  target_line = math.max(1, math.min(target_line, vim.api.nvim_buf_line_count(target_buf)))
  vim.api.nvim_win_set_cursor(winid, { target_line, 0 })
  if from_float then
    vim.schedule(function()
      require("parley.discussion_window").open_current_line(bufnr, { cursor_line = target_line })
    end)
  end
end

--- Given a sorted discussion list and the current buffer context, return the
--- index of the "current" discussion (the last one in the current file whose
--- mapped local_line <= cursor_row), or 0 when no match.
---
--- @param sorted    parley.Discussion[]
--- @param rel_path  string
--- @param cursor_row integer   0-indexed cursor row
--- @param mappings  table<string, parley.anchor.Mapping>
--- @return integer  1-based index in `sorted`, or 0
function M._current_index(sorted, rel_path, cursor_row, mappings)
  local best = 0
  for i, disc in ipairs(sorted) do
    if disc.file == rel_path then
      local mapping = mappings and mappings[disc.id]
      local local_line = mapping and mapping.local_line or disc.line
      if local_line and (local_line - 1) <= cursor_row then
        best = i
      end
    end
  end
  return best
end

-- ---------------------------------------------------------------------------
-- Public API — buffer-scoped
-- ---------------------------------------------------------------------------

--- Jump to the next commented line after the cursor in the current buffer.
---
--- If the cursor is already on a commented line it is skipped — the function
--- always moves forward to a *different* line.  When past the last mark the
--- navigation wraps silently to the first mark.  When there are no marks a
--- notification is emitted and the cursor is unchanged.
---
--- When called from a discussion float the buffer is transparently resolved to
--- the owning source buffer so that navigation works regardless of focus.
---
--- @param bufnr integer  Buffer to navigate within (usually the current buffer)
--- @param opts? { filter?: 'unresolved' }
function M.buf_next(bufnr, opts)
  opts = opts or {}
  local original_bufnr = bufnr
  bufnr = require("parley.discussion_window").resolve_source_bufnr(bufnr)
  local window_helpers = require("parley.discussion_window.window")
  local winid = window_helpers.resolve_source_winid(bufnr, nil) or 0

  local rows = M._unique_rows(bufnr, opts.filter)

  if #rows == 0 then
    local label = opts.filter == "unresolved" and "unresolved discussions" or "comments"
    vim.notify("No Parley " .. label .. " in this buffer", vim.log.levels.INFO)
    return
  end

  -- Current cursor row, 0-indexed.
  local cursor = vim.api.nvim_win_get_cursor(winid)[1] - 1

  -- Find the first row strictly greater than the cursor.
  local target = nil
  for _, row in ipairs(rows) do
    if row > cursor then
      target = row
      break
    end
  end

  -- Nothing found ahead — wrap to the first mark.
  if target == nil then
    target = rows[1]
  end

  local from_float = original_bufnr ~= bufnr
  if from_float then
    require("parley.discussion_window").close(bufnr)
  end
  vim.api.nvim_set_current_win(winid)
  vim.api.nvim_win_set_cursor(winid, { target + 1, 0 })
  if from_float then
    local target_line = target + 1
    vim.schedule(function()
      require("parley.discussion_window").open_current_line(bufnr, { cursor_line = target_line })
    end)
  end
end

--- Jump to the previous commented line before the cursor in the current buffer.
---
--- If the cursor is already on a commented line it is skipped — the function
--- always moves backward to a *different* line.  When before the first mark
--- the navigation wraps silently to the last mark.  When there are no marks a
--- notification is emitted and the cursor is unchanged.
---
--- When called from a discussion float the buffer is transparently resolved to
--- the owning source buffer so that navigation works regardless of focus.
---
--- @param bufnr integer  Buffer to navigate within (usually the current buffer)
--- @param opts? { filter?: 'unresolved' }
function M.buf_prev(bufnr, opts)
  opts = opts or {}
  local original_bufnr = bufnr
  bufnr = require("parley.discussion_window").resolve_source_bufnr(bufnr)
  local window_helpers = require("parley.discussion_window.window")
  local winid = window_helpers.resolve_source_winid(bufnr, nil) or 0

  local rows = M._unique_rows(bufnr, opts.filter)

  if #rows == 0 then
    local label = opts.filter == "unresolved" and "unresolved discussions" or "comments"
    vim.notify("No Parley " .. label .. " in this buffer", vim.log.levels.INFO)
    return
  end

  -- Current cursor row, 0-indexed.
  local cursor = vim.api.nvim_win_get_cursor(winid)[1] - 1

  -- Find the last row strictly less than the cursor (walk in reverse).
  local target = nil
  for i = #rows, 1, -1 do
    if rows[i] < cursor then
      target = rows[i]
      break
    end
  end

  -- Nothing found behind — wrap to the last mark.
  if target == nil then
    target = rows[#rows]
  end

  local from_float = original_bufnr ~= bufnr
  if from_float then
    require("parley.discussion_window").close(bufnr)
  end
  vim.api.nvim_set_current_win(winid)
  vim.api.nvim_win_set_cursor(winid, { target + 1, 0 })
  if from_float then
    local target_line = target + 1
    vim.schedule(function()
      require("parley.discussion_window").open_current_line(bufnr, { cursor_line = target_line })
    end)
  end
end

-- ---------------------------------------------------------------------------
-- Public API — review-scoped
-- ---------------------------------------------------------------------------

--- Jump to the next discussion across all files in the review.
---
--- Discussions are ordered by (file, line) in PR-diff space.  The current
--- position is determined by the buffer's rel_path and the cursor row mapped
--- through the anchor table.  When the next discussion is in a different
--- file, the file is opened with `vim.cmd("edit …")` — or, when the current
--- buffer is a diffview-aliased buffer, by switching diffview's active file
--- via diffview_integration.goto_file instead, so the diff layout and file
--- panel selection stay in sync. Navigation wraps silently at the end of
--- the last file.
---
--- When called from a discussion float the buffer is transparently resolved to
--- the owning source buffer so that navigation works regardless of focus.
---
--- @param bufnr integer  Source buffer (used to look up review data)
--- @param opts? { filter?: 'unresolved' }
function M.review_next(bufnr, opts)
  opts = opts or {}
  local original_bufnr = bufnr
  bufnr = require("parley.discussion_window").resolve_source_bufnr(bufnr)
  local window_helpers = require("parley.discussion_window.window")
  local winid = window_helpers.resolve_source_winid(bufnr, nil) or 0

  local context_repository = require("parley.repositories.context")
  local review_repository = require("parley.repositories.review")

  local ctx = context_repository.get(bufnr)
  if not ctx or not ctx.rel_path then
    vim.notify("No Parley review in this buffer", vim.log.levels.INFO)
    return
  end

  local sorted = M._sorted_review_discussions(bufnr, opts.filter)
  if not sorted or #sorted == 0 then
    local label = opts.filter == "unresolved" and "unresolved discussions" or "discussions"
    vim.notify("No Parley " .. label .. " with available file locations", vim.log.levels.WARN)
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(winid)[1] - 1
  local snapshot = review_repository.get(bufnr)
  local mappings = snapshot and snapshot.all_mappings or {}
  local cur_idx = M._current_index(sorted, ctx.rel_path, cursor, mappings)

  -- Next index with wrap-around.
  local target_idx = (cur_idx % #sorted) + 1
  local disc = sorted[target_idx]
  if not disc.file or disc.file == "" then
    vim.notify("Cannot navigate to a discussion without a file path", vim.log.levels.WARN)
    return
  end

  local vcs_root = ctx.vcs_info and ctx.vcs_info.root or ""
  local mapping = mappings[disc.id]
  local target_line = (mapping and mapping.local_line) or disc.line
  local head_sha = snapshot and snapshot.review and snapshot.review.head_sha

  goto_discussion(bufnr, winid, original_bufnr, ctx, vcs_root, head_sha, disc, target_line)
end

--- Jump to the previous discussion across all files in the review.
---
--- Mirror of review_next: walks backward through the (file, line)-sorted
--- discussion list with silent wrap-around.
---
--- When called from a discussion float the buffer is transparently resolved to
--- the owning source buffer so that navigation works regardless of focus.
---
--- @param bufnr integer  Source buffer (used to look up review data)
--- @param opts? { filter?: 'unresolved' }
function M.review_prev(bufnr, opts)
  opts = opts or {}
  local original_bufnr = bufnr
  bufnr = require("parley.discussion_window").resolve_source_bufnr(bufnr)
  local window_helpers = require("parley.discussion_window.window")
  local winid = window_helpers.resolve_source_winid(bufnr, nil) or 0

  local context_repository = require("parley.repositories.context")
  local review_repository = require("parley.repositories.review")

  local ctx = context_repository.get(bufnr)
  if not ctx or not ctx.rel_path then
    vim.notify("No Parley review in this buffer", vim.log.levels.INFO)
    return
  end

  local sorted = M._sorted_review_discussions(bufnr, opts.filter)
  if not sorted or #sorted == 0 then
    local label = opts.filter == "unresolved" and "unresolved discussions" or "discussions"
    vim.notify("No Parley " .. label .. " with available file locations", vim.log.levels.WARN)
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(winid)[1] - 1
  local snapshot = review_repository.get(bufnr)
  local mappings = snapshot and snapshot.all_mappings or {}
  local cur_idx = M._current_index(sorted, ctx.rel_path, cursor, mappings)

  -- Previous index with wrap-around.
  -- When cur_idx == 0 (no match) we want the last element.
  local target_idx
  if cur_idx <= 1 then
    target_idx = #sorted
  else
    target_idx = cur_idx - 1
  end
  local disc = sorted[target_idx]
  if not disc.file or disc.file == "" then
    vim.notify("Cannot navigate to a discussion without a file path", vim.log.levels.WARN)
    return
  end

  local vcs_root = ctx.vcs_info and ctx.vcs_info.root or ""
  local mapping = mappings[disc.id]
  local target_line = (mapping and mapping.local_line) or disc.line
  local head_sha = snapshot and snapshot.review and snapshot.review.head_sha

  goto_discussion(bufnr, winid, original_bufnr, ctx, vcs_root, head_sha, disc, target_line)
end

return M
