--- parley.nav — Navigation between commented lines.
---
--- Provides next/prev functions that jump the cursor between lines that have
--- parley extmarks (placed by parley.signs.render). Keymaps for these
--- functions are registered globally in parley.init.setup().
---
--- Design notes:
---   • Both functions operate on the **current window's** cursor.
---   • Rows are deduplicated: multiple discussions on the same line produce
---     only one navigation stop.
---   • Wrap-around is silent (consistent with built-in ]c diff navigation).
---   • When no marks exist a brief vim.notify is emitted and the cursor is
---     left unchanged.

local M = {}

-- ---------------------------------------------------------------------------
-- Private helpers
-- ---------------------------------------------------------------------------

--- Return a deduplicated, ascending list of 0-indexed row numbers that have
--- at least one parley extmark in `bufnr`.
---
--- @param bufnr integer
--- @return integer[]
function M._unique_rows(bufnr)
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

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Jump to the next commented line after the cursor.
---
--- If the cursor is already on a commented line it is skipped — the function
--- always moves forward to a *different* line.  When past the last mark the
--- navigation wraps silently to the first mark.  When there are no marks a
--- notification is emitted and the cursor is unchanged.
---
--- @param bufnr integer  Buffer to navigate within (usually the current buffer)
function M.next(bufnr)
  local rows = M._unique_rows(bufnr)

  if #rows == 0 then
    vim.notify("No Parley comments in this buffer", vim.log.levels.INFO)
    return
  end

  -- Current cursor row, 0-indexed.
  local cursor = vim.api.nvim_win_get_cursor(0)[1] - 1

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

  vim.api.nvim_win_set_cursor(0, { target + 1, 0 })
end

--- Jump to the previous commented line before the cursor.
---
--- If the cursor is already on a commented line it is skipped — the function
--- always moves backward to a *different* line.  When before the first mark
--- the navigation wraps silently to the last mark.  When there are no marks a
--- notification is emitted and the cursor is unchanged.
---
--- @param bufnr integer  Buffer to navigate within (usually the current buffer)
function M.prev(bufnr)
  local rows = M._unique_rows(bufnr)

  if #rows == 0 then
    vim.notify("No Parley comments in this buffer", vim.log.levels.INFO)
    return
  end

  -- Current cursor row, 0-indexed.
  local cursor = vim.api.nvim_win_get_cursor(0)[1] - 1

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

  vim.api.nvim_win_set_cursor(0, { target + 1, 0 })
end

return M
