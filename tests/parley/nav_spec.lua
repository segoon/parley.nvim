--- tests/parley/nav_spec.lua — Navigation keymaps (Step 12)
---
--- All tests are synchronous. Strategy:
---   1. Create a scratch buffer with enough lines.
---   2. Place parley extmarks via nvim_buf_set_extmark.
---   3. Make the buffer current so cursor operations work.
---   4. Set cursor position with nvim_win_set_cursor(0, {row, col}).
---   5. Call nav.next / nav.prev.
---   6. Assert nvim_win_get_cursor(0) returns the expected 1-indexed position.
---
--- Cursor positions are always 1-indexed (Neovim convention for nvim_win_*).

local nav = require("parley.nav")
local signs = require("parley.signs")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Create a scratch buffer with `n` empty lines and make it current.
--- Returns bufnr.
--- @param n integer
--- @return integer
local function scratch(n)
  local bufnr = vim.api.nvim_create_buf(false, true)
  local lines = {}
  for _ = 1, n do
    lines[#lines + 1] = ""
  end
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(bufnr)
  return bufnr
end

--- Place a parley extmark at 0-indexed `row` in `bufnr`.
--- @param bufnr integer
--- @param row   integer  0-indexed
local function place_mark(bufnr, row)
  local ns = signs._get_ns()
  vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, {})
end

--- Get the current 1-indexed cursor row.
--- @return integer
local function cursor_row()
  return vim.api.nvim_win_get_cursor(0)[1]
end

--- Set the 1-indexed cursor row (col 0).
--- @param row integer  1-indexed
local function set_cursor(row)
  vim.api.nvim_win_set_cursor(0, { row, 0 })
end

-- Spy on vim.notify so we can assert it was (or was not) called.
local notify_calls = {}
local orig_notify = vim.notify

local function install_notify_spy()
  notify_calls = {}
  vim.notify = function(msg, level)
    notify_calls[#notify_calls + 1] = { msg = msg, level = level }
  end
end

local function restore_notify()
  vim.notify = orig_notify
end

-- ---------------------------------------------------------------------------
-- _unique_rows
-- ---------------------------------------------------------------------------

describe("nav._unique_rows", function()
  it("returns an empty list when no extmarks are present", function()
    local bufnr = scratch(5)
    assert.same({}, nav._unique_rows(bufnr))
  end)

  it("returns each marked row exactly once when all marks are on distinct rows", function()
    local bufnr = scratch(10)
    place_mark(bufnr, 1) -- row 1 (0-indexed)
    place_mark(bufnr, 4)
    place_mark(bufnr, 7)
    assert.same({ 1, 4, 7 }, nav._unique_rows(bufnr))
  end)

  it("deduplicates rows when multiple marks share the same row", function()
    local bufnr = scratch(10)
    place_mark(bufnr, 3)
    place_mark(bufnr, 3) -- duplicate
    place_mark(bufnr, 3) -- duplicate
    assert.same({ 3 }, nav._unique_rows(bufnr))
  end)

  it("returns rows in ascending order", function()
    local bufnr = scratch(10)
    -- Insert out of order is impossible via nvim_buf_set_extmark (always sorted),
    -- but verify the contract explicitly.
    place_mark(bufnr, 0)
    place_mark(bufnr, 5)
    place_mark(bufnr, 2)
    local rows = nav._unique_rows(bufnr)
    assert.equal(3, #rows)
    assert.is_true(rows[1] < rows[2])
    assert.is_true(rows[2] < rows[3])
  end)

  it("deduplication + ordering combined", function()
    local bufnr = scratch(10)
    place_mark(bufnr, 6)
    place_mark(bufnr, 2)
    place_mark(bufnr, 6) -- dup of row 6
    place_mark(bufnr, 2) -- dup of row 2
    place_mark(bufnr, 4)
    assert.same({ 2, 4, 6 }, nav._unique_rows(bufnr))
  end)
end)

-- ---------------------------------------------------------------------------
-- nav.next
-- ---------------------------------------------------------------------------

describe("nav.next", function()
  before_each(install_notify_spy)
  after_each(restore_notify)

  it("does nothing and notifies when there are no marks", function()
    local bufnr = scratch(5)
    set_cursor(2)
    nav.next(bufnr)
    assert.equal(2, cursor_row()) -- cursor unchanged
    assert.equal(1, #notify_calls)
  end)

  it("jumps to the first mark when cursor is above all marks", function()
    local bufnr = scratch(10)
    place_mark(bufnr, 3) -- row 3 → line 4
    place_mark(bufnr, 7) -- row 7 → line 8
    set_cursor(1) -- above row 3
    nav.next(bufnr)
    assert.equal(4, cursor_row()) -- row 3 → line 4
  end)

  it("jumps to the next mark when cursor is on a mark (skips current line)", function()
    local bufnr = scratch(10)
    place_mark(bufnr, 2) -- line 3
    place_mark(bufnr, 5) -- line 6
    set_cursor(3) -- ON line 3 (row 2)
    nav.next(bufnr)
    assert.equal(6, cursor_row()) -- moved to line 6
  end)

  it("jumps to the mark immediately after the cursor when cursor is between marks", function()
    local bufnr = scratch(10)
    place_mark(bufnr, 1) -- line 2
    place_mark(bufnr, 4) -- line 5
    place_mark(bufnr, 8) -- line 9
    set_cursor(3) -- between row 1 and row 4
    nav.next(bufnr)
    assert.equal(5, cursor_row()) -- row 4 → line 5
  end)

  it("wraps silently to the first mark when cursor is past the last mark", function()
    local bufnr = scratch(10)
    place_mark(bufnr, 2) -- line 3
    place_mark(bufnr, 5) -- line 6
    set_cursor(9) -- past row 5
    nav.next(bufnr)
    assert.equal(3, cursor_row()) -- wrapped to first: row 2 → line 3
    assert.equal(0, #notify_calls) -- silent wrap
  end)

  it("wraps to first when cursor is exactly on the last mark", function()
    local bufnr = scratch(10)
    place_mark(bufnr, 1) -- line 2
    place_mark(bufnr, 6) -- line 7
    set_cursor(7) -- ON line 7 (last mark)
    nav.next(bufnr)
    assert.equal(2, cursor_row()) -- wrapped to first: row 1 → line 2
  end)

  it("single mark: wraps to itself when cursor is on the mark", function()
    local bufnr = scratch(5)
    place_mark(bufnr, 2) -- line 3
    set_cursor(3) -- on the only mark
    nav.next(bufnr)
    assert.equal(3, cursor_row()) -- wraps back to itself
    assert.equal(0, #notify_calls)
  end)

  it("single mark: jumps to it when cursor is above", function()
    local bufnr = scratch(5)
    place_mark(bufnr, 3) -- line 4
    set_cursor(1)
    nav.next(bufnr)
    assert.equal(4, cursor_row())
  end)
end)

-- ---------------------------------------------------------------------------
-- nav.prev
-- ---------------------------------------------------------------------------

describe("nav.prev", function()
  before_each(install_notify_spy)
  after_each(restore_notify)

  it("does nothing and notifies when there are no marks", function()
    local bufnr = scratch(5)
    set_cursor(3)
    nav.prev(bufnr)
    assert.equal(3, cursor_row())
    assert.equal(1, #notify_calls)
  end)

  it("jumps to the last mark when cursor is below all marks", function()
    local bufnr = scratch(10)
    place_mark(bufnr, 2) -- line 3
    place_mark(bufnr, 6) -- line 7
    set_cursor(10) -- below row 6
    nav.prev(bufnr)
    assert.equal(7, cursor_row()) -- row 6 → line 7
  end)

  it("jumps to the prev mark when cursor is on a mark (skips current line)", function()
    local bufnr = scratch(10)
    place_mark(bufnr, 2) -- line 3
    place_mark(bufnr, 5) -- line 6
    set_cursor(6) -- ON line 6 (row 5)
    nav.prev(bufnr)
    assert.equal(3, cursor_row()) -- moved to line 3
  end)

  it("jumps to the mark immediately before the cursor when cursor is between marks", function()
    local bufnr = scratch(10)
    place_mark(bufnr, 1) -- line 2
    place_mark(bufnr, 4) -- line 5
    place_mark(bufnr, 8) -- line 9
    set_cursor(7) -- between row 4 and row 8
    nav.prev(bufnr)
    assert.equal(5, cursor_row()) -- row 4 → line 5
  end)

  it("wraps silently to the last mark when cursor is before the first mark", function()
    local bufnr = scratch(10)
    place_mark(bufnr, 3) -- line 4
    place_mark(bufnr, 7) -- line 8
    set_cursor(1) -- before row 3
    nav.prev(bufnr)
    assert.equal(8, cursor_row()) -- wrapped to last: row 7 → line 8
    assert.equal(0, #notify_calls)
  end)

  it("wraps to last when cursor is exactly on the first mark", function()
    local bufnr = scratch(10)
    place_mark(bufnr, 1) -- line 2
    place_mark(bufnr, 6) -- line 7
    set_cursor(2) -- ON line 2 (first mark)
    nav.prev(bufnr)
    assert.equal(7, cursor_row()) -- wrapped to last: row 6 → line 7
  end)

  it("single mark: wraps to itself when cursor is on the mark", function()
    local bufnr = scratch(5)
    place_mark(bufnr, 2) -- line 3
    set_cursor(3)
    nav.prev(bufnr)
    assert.equal(3, cursor_row())
    assert.equal(0, #notify_calls)
  end)

  it("single mark: jumps to it when cursor is below", function()
    local bufnr = scratch(5)
    place_mark(bufnr, 1) -- line 2
    set_cursor(5)
    nav.prev(bufnr)
    assert.equal(2, cursor_row())
  end)
end)
