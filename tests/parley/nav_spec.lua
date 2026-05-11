--- tests/parley/nav_spec.lua — Navigation functions
---
--- All tests are synchronous.
---
--- Buffer-scoped (buf_next / buf_prev) strategy:
---   1. Create a scratch buffer with enough lines.
---   2. Place parley extmarks via nvim_buf_set_extmark.
---   3. Make the buffer current so cursor operations work.
---   4. Set cursor position with nvim_win_set_cursor(0, {row, col}).
---   5. Call nav.buf_next / nav.buf_prev.
---   6. Assert nvim_win_get_cursor(0) returns the expected 1-indexed position.
---
--- Review-scoped (review_next / review_prev) strategy:
---   • Stub context_repository.get to supply rel_path + vcs_info.root.
---   • Stub review_repository._views to supply per-buffer mappings.
---   • Stub read_service.list_discussions to supply all_discussions.
---   • Spy on vim.cmd to capture cross-file edit calls.
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

-- Spy on vim.cmd to capture edit calls.
local cmd_calls = {}
local orig_cmd = vim.cmd

local function install_cmd_spy()
  cmd_calls = {}
  vim.cmd = function(arg)
    cmd_calls[#cmd_calls + 1] = arg
  end
end

local function restore_cmd()
  vim.cmd = orig_cmd
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
-- _sorted_review_discussions
-- ---------------------------------------------------------------------------

describe("nav._sorted_review_discussions", function()
  local saved_read

  before_each(function()
    saved_read = package.loaded["parley.services.read"]
  end)

  after_each(function()
    package.loaded["parley.services.read"] = saved_read
  end)

  it("returns nil/empty when list_discussions returns empty", function()
    package.loaded["parley.services.read"] = {
      list_discussions = function(_bufnr, _opts)
        return {}
      end,
    }
    local result = nav._sorted_review_discussions(1)
    assert.same({}, result)
  end)

  it("sorts by file then by line", function()
    package.loaded["parley.services.read"] = {
      list_discussions = function(_bufnr, _opts)
        return {
          { id = "c", file = "b.lua", line = 5, resolved = false, comments = {} },
          { id = "a", file = "a.lua", line = 10, resolved = false, comments = {} },
          { id = "b", file = "a.lua", line = 3, resolved = false, comments = {} },
        }
      end,
    }
    local result = nav._sorted_review_discussions(1)
    assert.equal(3, #result)
    assert.equal("a.lua", result[1].file)
    assert.equal(3, result[1].line)
    assert.equal("a.lua", result[2].file)
    assert.equal(10, result[2].line)
    assert.equal("b.lua", result[3].file)
    assert.equal(5, result[3].line)
  end)
end)

-- ---------------------------------------------------------------------------
-- _current_index
-- ---------------------------------------------------------------------------

describe("nav._current_index", function()
  local sorted = {
    { id = "1", file = "a.lua", line = 5, resolved = false, comments = {} },
    { id = "2", file = "a.lua", line = 10, resolved = false, comments = {} },
    { id = "3", file = "b.lua", line = 2, resolved = false, comments = {} },
  }
  local mappings = {
    ["1"] = { local_line = 5 },
    ["2"] = { local_line = 10 },
    ["3"] = { local_line = 2 },
  }

  it("returns 0 when current file has no discussions", function()
    local idx = nav._current_index(sorted, "c.lua", 5, mappings)
    assert.equal(0, idx)
  end)

  it("returns 0 when cursor is above all discussions in current file", function()
    local idx = nav._current_index(sorted, "a.lua", 2, mappings) -- cursor row 2 (0-idx) < local_line 5
    assert.equal(0, idx)
  end)

  it("returns the last discussion whose local_line <= cursor+1", function()
    -- cursor_row=4 (0-indexed) → 1-indexed line 5; local_line 5 <= 5: matches disc 1
    local idx = nav._current_index(sorted, "a.lua", 4, mappings)
    assert.equal(1, idx)
  end)

  it("returns the highest matching index when cursor is past multiple", function()
    -- cursor_row=9 (0-indexed) → line 10; both disc 1 (line 5) and disc 2 (line 10) match
    local idx = nav._current_index(sorted, "a.lua", 9, mappings)
    assert.equal(2, idx)
  end)

  it("uses disc.line as fallback when mapping is absent", function()
    -- disc[3].file=="b.lua", disc.line=2; condition: (local_line-1) <= cursor_row
    -- cursor_row=0 (0-indexed): (2-1)=1 <= 0 → no match
    local idx = nav._current_index(sorted, "b.lua", 0, {})
    assert.equal(0, idx)
    -- cursor_row=1: (2-1)=1 <= 1 → matches disc[3]
    local idx2 = nav._current_index(sorted, "b.lua", 1, {})
    assert.equal(3, idx2)
    -- cursor_row=10: also matches disc[3]
    local idx3 = nav._current_index(sorted, "b.lua", 10, {})
    assert.equal(3, idx3)
  end)
end)

-- ---------------------------------------------------------------------------
-- nav.buf_next
-- ---------------------------------------------------------------------------

describe("nav.buf_next", function()
  before_each(install_notify_spy)
  after_each(restore_notify)

  it("does nothing and notifies when there are no marks", function()
    local bufnr = scratch(5)
    set_cursor(2)
    nav.buf_next(bufnr)
    assert.equal(2, cursor_row()) -- cursor unchanged
    assert.equal(1, #notify_calls)
  end)

  it("jumps to the first mark when cursor is above all marks", function()
    local bufnr = scratch(10)
    place_mark(bufnr, 3) -- row 3 → line 4
    place_mark(bufnr, 7) -- row 7 → line 8
    set_cursor(1) -- above row 3
    nav.buf_next(bufnr)
    assert.equal(4, cursor_row()) -- row 3 → line 4
  end)

  it("jumps to the next mark when cursor is on a mark (skips current line)", function()
    local bufnr = scratch(10)
    place_mark(bufnr, 2) -- line 3
    place_mark(bufnr, 5) -- line 6
    set_cursor(3) -- ON line 3 (row 2)
    nav.buf_next(bufnr)
    assert.equal(6, cursor_row()) -- moved to line 6
  end)

  it("jumps to the mark immediately after the cursor when cursor is between marks", function()
    local bufnr = scratch(10)
    place_mark(bufnr, 1) -- line 2
    place_mark(bufnr, 4) -- line 5
    place_mark(bufnr, 8) -- line 9
    set_cursor(3) -- between row 1 and row 4
    nav.buf_next(bufnr)
    assert.equal(5, cursor_row()) -- row 4 → line 5
  end)

  it("wraps silently to the first mark when cursor is past the last mark", function()
    local bufnr = scratch(10)
    place_mark(bufnr, 2) -- line 3
    place_mark(bufnr, 5) -- line 6
    set_cursor(9) -- past row 5
    nav.buf_next(bufnr)
    assert.equal(3, cursor_row()) -- wrapped to first: row 2 → line 3
    assert.equal(0, #notify_calls) -- silent wrap
  end)

  it("wraps to first when cursor is exactly on the last mark", function()
    local bufnr = scratch(10)
    place_mark(bufnr, 1) -- line 2
    place_mark(bufnr, 6) -- line 7
    set_cursor(7) -- ON line 7 (last mark)
    nav.buf_next(bufnr)
    assert.equal(2, cursor_row()) -- wrapped to first: row 1 → line 2
  end)

  it("single mark: wraps to itself when cursor is on the mark", function()
    local bufnr = scratch(5)
    place_mark(bufnr, 2) -- line 3
    set_cursor(3) -- on the only mark
    nav.buf_next(bufnr)
    assert.equal(3, cursor_row()) -- wraps back to itself
    assert.equal(0, #notify_calls)
  end)

  it("single mark: jumps to it when cursor is above", function()
    local bufnr = scratch(5)
    place_mark(bufnr, 3) -- line 4
    set_cursor(1)
    nav.buf_next(bufnr)
    assert.equal(4, cursor_row())
  end)
end)

-- ---------------------------------------------------------------------------
-- nav.buf_prev
-- ---------------------------------------------------------------------------

describe("nav.buf_prev", function()
  before_each(install_notify_spy)
  after_each(restore_notify)

  it("does nothing and notifies when there are no marks", function()
    local bufnr = scratch(5)
    set_cursor(3)
    nav.buf_prev(bufnr)
    assert.equal(3, cursor_row())
    assert.equal(1, #notify_calls)
  end)

  it("jumps to the last mark when cursor is below all marks", function()
    local bufnr = scratch(10)
    place_mark(bufnr, 2) -- line 3
    place_mark(bufnr, 6) -- line 7
    set_cursor(10) -- below row 6
    nav.buf_prev(bufnr)
    assert.equal(7, cursor_row()) -- row 6 → line 7
  end)

  it("jumps to the prev mark when cursor is on a mark (skips current line)", function()
    local bufnr = scratch(10)
    place_mark(bufnr, 2) -- line 3
    place_mark(bufnr, 5) -- line 6
    set_cursor(6) -- ON line 6 (row 5)
    nav.buf_prev(bufnr)
    assert.equal(3, cursor_row()) -- moved to line 3
  end)

  it("jumps to the mark immediately before the cursor when cursor is between marks", function()
    local bufnr = scratch(10)
    place_mark(bufnr, 1) -- line 2
    place_mark(bufnr, 4) -- line 5
    place_mark(bufnr, 8) -- line 9
    set_cursor(7) -- between row 4 and row 8
    nav.buf_prev(bufnr)
    assert.equal(5, cursor_row()) -- row 4 → line 5
  end)

  it("wraps silently to the last mark when cursor is before the first mark", function()
    local bufnr = scratch(10)
    place_mark(bufnr, 3) -- line 4
    place_mark(bufnr, 7) -- line 8
    set_cursor(1) -- before row 3
    nav.buf_prev(bufnr)
    assert.equal(8, cursor_row()) -- wrapped to last: row 7 → line 8
    assert.equal(0, #notify_calls)
  end)

  it("wraps to last when cursor is exactly on the first mark", function()
    local bufnr = scratch(10)
    place_mark(bufnr, 1) -- line 2
    place_mark(bufnr, 6) -- line 7
    set_cursor(2) -- ON line 2 (first mark)
    nav.buf_prev(bufnr)
    assert.equal(7, cursor_row()) -- wrapped to last: row 6 → line 7
  end)

  it("single mark: wraps to itself when cursor is on the mark", function()
    local bufnr = scratch(5)
    place_mark(bufnr, 2) -- line 3
    set_cursor(3)
    nav.buf_prev(bufnr)
    assert.equal(3, cursor_row())
    assert.equal(0, #notify_calls)
  end)

  it("single mark: jumps to it when cursor is below", function()
    local bufnr = scratch(5)
    place_mark(bufnr, 1) -- line 2
    set_cursor(5)
    nav.buf_prev(bufnr)
    assert.equal(2, cursor_row())
  end)
end)

-- ---------------------------------------------------------------------------
-- Review-scoped helpers: stubs
-- ---------------------------------------------------------------------------

local saved_context_repo
local saved_review_repo
local saved_read_service

local function setup_review_stubs(ctx, views, discussions)
  saved_context_repo = package.loaded["parley.repositories.context"]
  saved_review_repo = package.loaded["parley.repositories.review"]
  saved_read_service = package.loaded["parley.services.read"]

  package.loaded["parley.repositories.context"] = {
    get = function(_bufnr)
      return ctx
    end,
  }
  package.loaded["parley.repositories.review"] = {
    _views = views,
  }
  package.loaded["parley.services.read"] = {
    list_discussions = function(_bufnr, _opts)
      return discussions
    end,
  }
end

local function teardown_review_stubs()
  package.loaded["parley.repositories.context"] = saved_context_repo
  package.loaded["parley.repositories.review"] = saved_review_repo
  package.loaded["parley.services.read"] = saved_read_service
end

-- ---------------------------------------------------------------------------
-- nav.review_next
-- ---------------------------------------------------------------------------

describe("nav.review_next", function()
  before_each(function()
    install_notify_spy()
    install_cmd_spy()
  end)
  after_each(function()
    restore_notify()
    restore_cmd()
    teardown_review_stubs()
  end)

  it("notifies and does nothing when context has no rel_path", function()
    local bufnr = scratch(5)
    setup_review_stubs({ kind = "regular" }, {}, {})
    set_cursor(1)
    nav.review_next(bufnr)
    assert.equal(1, cursor_row())
    assert.equal(1, #notify_calls)
    assert.equal(0, #cmd_calls)
  end)

  it("notifies and does nothing when there are no discussions", function()
    local bufnr = scratch(5)
    setup_review_stubs({ rel_path = "a.lua", vcs_info = { root = "/repo" } }, { [bufnr] = { mappings = {} } }, {})
    set_cursor(1)
    nav.review_next(bufnr)
    assert.equal(1, cursor_row())
    assert.equal(1, #notify_calls)
    assert.equal(0, #cmd_calls)
  end)

  it("jumps within the same file without calling vim.cmd", function()
    local bufnr = scratch(20)
    local discussions = {
      { id = "1", file = "a.lua", line = 3, resolved = false, comments = {} },
      { id = "2", file = "a.lua", line = 10, resolved = false, comments = {} },
    }
    local mappings = {
      ["1"] = { local_line = 3 },
      ["2"] = { local_line = 10 },
    }
    setup_review_stubs(
      { rel_path = "a.lua", vcs_info = { root = "/repo" } },
      { [bufnr] = { mappings = mappings } },
      discussions
    )
    set_cursor(1) -- above both discussions; _current_index = 0
    nav.review_next(bufnr)
    -- cur_idx=0 → target=(0 % 2)+1 = 1 → disc[1] = line 3
    assert.equal(3, cursor_row())
    assert.equal(0, #cmd_calls)
    assert.equal(0, #notify_calls)
  end)

  it("advances to the next discussion in the same file", function()
    local bufnr = scratch(20)
    local discussions = {
      { id = "1", file = "a.lua", line = 3, resolved = false, comments = {} },
      { id = "2", file = "a.lua", line = 10, resolved = false, comments = {} },
    }
    local mappings = {
      ["1"] = { local_line = 3 },
      ["2"] = { local_line = 10 },
    }
    setup_review_stubs(
      { rel_path = "a.lua", vcs_info = { root = "/repo" } },
      { [bufnr] = { mappings = mappings } },
      discussions
    )
    set_cursor(3) -- on line 3 → _current_index = 1
    nav.review_next(bufnr)
    -- cur_idx=1 → target=(1%2)+1=2 → disc[2] = line 10
    assert.equal(10, cursor_row())
    assert.equal(0, #cmd_calls)
  end)

  it("wraps around silently to the first discussion", function()
    local bufnr = scratch(20)
    local discussions = {
      { id = "1", file = "a.lua", line = 3, resolved = false, comments = {} },
      { id = "2", file = "a.lua", line = 10, resolved = false, comments = {} },
    }
    local mappings = {
      ["1"] = { local_line = 3 },
      ["2"] = { local_line = 10 },
    }
    setup_review_stubs(
      { rel_path = "a.lua", vcs_info = { root = "/repo" } },
      { [bufnr] = { mappings = mappings } },
      discussions
    )
    set_cursor(10) -- on last discussion; _current_index = 2
    nav.review_next(bufnr)
    -- cur_idx=2 → target=(2%2)+1=1 → disc[1] = line 3
    assert.equal(3, cursor_row())
    assert.equal(0, #notify_calls)
    assert.equal(0, #cmd_calls)
  end)

  it("opens a different file with vim.cmd edit and sets cursor", function()
    -- Use a buffer large enough to accommodate target_line=7 even when vim.cmd is stubbed
    -- (the buffer doesn't actually switch, so cursor is placed in the same scratch buf).
    local bufnr = scratch(10)
    local discussions = {
      { id = "1", file = "a.lua", line = 5, resolved = false, comments = {} },
      { id = "2", file = "b.lua", line = 7, resolved = false, comments = {} },
    }
    local mappings = {
      ["1"] = { local_line = 5 },
      ["2"] = { local_line = 7 },
    }
    setup_review_stubs(
      { rel_path = "a.lua", vcs_info = { root = "/repo" } },
      { [bufnr] = { mappings = mappings } },
      discussions
    )
    set_cursor(5) -- on disc 1; _current_index = 1
    nav.review_next(bufnr)
    -- cur_idx=1 → target=(1%2)+1=2 → disc[2] = b.lua line 7
    assert.equal(1, #cmd_calls)
    assert.is_truthy(cmd_calls[1]:find("b.lua"))
  end)

  it("uses disc.line as fallback when no mapping exists", function()
    local bufnr = scratch(20)
    local discussions = {
      { id = "1", file = "a.lua", line = 4, resolved = false, comments = {} },
    }
    setup_review_stubs(
      { rel_path = "a.lua", vcs_info = { root = "/repo" } },
      { [bufnr] = { mappings = {} } },
      discussions
    )
    set_cursor(1) -- _current_index = 0
    nav.review_next(bufnr)
    -- target = disc[1]; no mapping → falls back to disc.line = 4
    assert.equal(4, cursor_row())
    assert.equal(0, #cmd_calls)
  end)
end)

-- ---------------------------------------------------------------------------
-- nav.review_prev
-- ---------------------------------------------------------------------------

describe("nav.review_prev", function()
  before_each(function()
    install_notify_spy()
    install_cmd_spy()
  end)
  after_each(function()
    restore_notify()
    restore_cmd()
    teardown_review_stubs()
  end)

  it("notifies and does nothing when context has no rel_path", function()
    local bufnr = scratch(5)
    setup_review_stubs({ kind = "regular" }, {}, {})
    set_cursor(1)
    nav.review_prev(bufnr)
    assert.equal(1, cursor_row())
    assert.equal(1, #notify_calls)
    assert.equal(0, #cmd_calls)
  end)

  it("notifies and does nothing when there are no discussions", function()
    local bufnr = scratch(5)
    setup_review_stubs({ rel_path = "a.lua", vcs_info = { root = "/repo" } }, { [bufnr] = { mappings = {} } }, {})
    set_cursor(1)
    nav.review_prev(bufnr)
    assert.equal(1, cursor_row())
    assert.equal(1, #notify_calls)
    assert.equal(0, #cmd_calls)
  end)

  it("wraps to the last discussion when cur_idx <= 1", function()
    local bufnr = scratch(20)
    local discussions = {
      { id = "1", file = "a.lua", line = 3, resolved = false, comments = {} },
      { id = "2", file = "a.lua", line = 10, resolved = false, comments = {} },
    }
    local mappings = {
      ["1"] = { local_line = 3 },
      ["2"] = { local_line = 10 },
    }
    setup_review_stubs(
      { rel_path = "a.lua", vcs_info = { root = "/repo" } },
      { [bufnr] = { mappings = mappings } },
      discussions
    )
    set_cursor(1) -- above both; cur_idx = 0
    nav.review_prev(bufnr)
    -- cur_idx=0 <=1 → target=#sorted=2 → disc[2] = line 10
    assert.equal(10, cursor_row())
    assert.equal(0, #notify_calls)
    assert.equal(0, #cmd_calls)
  end)

  it("steps back to the previous discussion in the same file", function()
    local bufnr = scratch(20)
    local discussions = {
      { id = "1", file = "a.lua", line = 3, resolved = false, comments = {} },
      { id = "2", file = "a.lua", line = 10, resolved = false, comments = {} },
    }
    local mappings = {
      ["1"] = { local_line = 3 },
      ["2"] = { local_line = 10 },
    }
    setup_review_stubs(
      { rel_path = "a.lua", vcs_info = { root = "/repo" } },
      { [bufnr] = { mappings = mappings } },
      discussions
    )
    set_cursor(10) -- on disc 2; cur_idx = 2
    nav.review_prev(bufnr)
    -- cur_idx=2 > 1 → target=2-1=1 → disc[1] = line 3
    assert.equal(3, cursor_row())
    assert.equal(0, #cmd_calls)
  end)

  it("opens a different file with vim.cmd edit and sets cursor", function()
    -- Use a buffer large enough to accommodate set_cursor(7) and target_line=5
    -- when vim.cmd is stubbed (no actual buffer switch occurs).
    local bufnr = scratch(10)
    local discussions = {
      { id = "1", file = "a.lua", line = 5, resolved = false, comments = {} },
      { id = "2", file = "b.lua", line = 7, resolved = false, comments = {} },
    }
    local mappings = {
      ["1"] = { local_line = 5 },
      ["2"] = { local_line = 7 },
    }
    setup_review_stubs(
      { rel_path = "b.lua", vcs_info = { root = "/repo" } },
      { [bufnr] = { mappings = mappings } },
      discussions
    )
    set_cursor(7) -- on disc 2; cur_idx = 2
    nav.review_prev(bufnr)
    -- cur_idx=2 > 1 → target=1 → disc[1] = a.lua line 5
    assert.equal(1, #cmd_calls)
    assert.is_truthy(cmd_calls[1]:find("a.lua"))
  end)

  it("wraps silently from last file back to last discussion overall", function()
    local bufnr = scratch(20)
    local discussions = {
      { id = "1", file = "a.lua", line = 3, resolved = false, comments = {} },
      { id = "2", file = "b.lua", line = 7, resolved = false, comments = {} },
    }
    local mappings = {
      ["1"] = { local_line = 3 },
      ["2"] = { local_line = 7 },
    }
    setup_review_stubs(
      { rel_path = "a.lua", vcs_info = { root = "/repo" } },
      { [bufnr] = { mappings = mappings } },
      discussions
    )
    set_cursor(3) -- on disc 1; cur_idx = 1
    nav.review_prev(bufnr)
    -- cur_idx=1 <=1 → target=2 → disc[2] = b.lua line 7
    assert.equal(1, #cmd_calls)
    assert.is_truthy(cmd_calls[1]:find("b.lua"))
    assert.equal(0, #notify_calls)
  end)
end)

-- ---------------------------------------------------------------------------
-- Navigation from discussion float buffer
-- ---------------------------------------------------------------------------
-- When any nav function is called with the bufnr of a discussion float (or its
-- input pane), resolve_source_bufnr must map it back to the owning source
-- buffer so that extmarks / review context are found correctly.

describe("nav from discussion float buffer", function()
  local saved_discussion_window
  local saved_window_helpers

  --- Stub both modules that nav uses when called from a float:
  ---   • discussion_window.resolve_source_bufnr  — maps float → source bufnr
  ---   • discussion_window.window.resolve_source_winid — maps source bufnr → winid
  ---
  --- `source_winid` defaults to 0 (current window) when not provided.
  ---@param float_bufnr integer
  ---@param source_bufnr integer
  ---@param source_winid? integer
  local function stub_float(float_bufnr, source_bufnr, source_winid)
    local winid = source_winid or 0

    saved_discussion_window = package.loaded["parley.discussion_window"]
    package.loaded["parley.discussion_window"] = {
      resolve_source_bufnr = function(bufnr)
        if bufnr == float_bufnr then
          return source_bufnr
        end
        return bufnr
      end,
    }

    saved_window_helpers = package.loaded["parley.discussion_window.window"]
    package.loaded["parley.discussion_window.window"] = {
      resolve_source_winid = function(_bufnr, _preferred)
        return winid
      end,
    }
  end

  local function restore_stubs()
    package.loaded["parley.discussion_window"] = saved_discussion_window
    package.loaded["parley.discussion_window.window"] = saved_window_helpers
  end

  before_each(install_notify_spy)
  after_each(function()
    restore_notify()
    restore_stubs()
    teardown_review_stubs()
  end)

  it("buf_next resolves float bufnr to source and sets cursor in source window", function()
    local source_bufnr = scratch(10)
    place_mark(source_bufnr, 3) -- row 3 → line 4
    place_mark(source_bufnr, 7) -- row 7 → line 8

    -- scratch() made source_bufnr current, so window 0 shows it.
    -- The float is a separate scratch buf — its line count is 1.
    local float_bufnr = vim.api.nvim_create_buf(false, true)
    stub_float(float_bufnr, source_bufnr) -- source_winid = 0 (current)

    set_cursor(1) -- cursor in source window, above all marks

    nav.buf_next(float_bufnr)

    assert.equal(4, cursor_row()) -- moved to row 3 → line 4
    assert.equal(0, #notify_calls)
  end)

  it("buf_prev resolves float bufnr to source and sets cursor in source window", function()
    local source_bufnr = scratch(10)
    place_mark(source_bufnr, 2) -- row 2 → line 3
    place_mark(source_bufnr, 6) -- row 6 → line 7

    local float_bufnr = vim.api.nvim_create_buf(false, true)
    stub_float(float_bufnr, source_bufnr)

    set_cursor(10) -- below all marks

    nav.buf_prev(float_bufnr)

    assert.equal(7, cursor_row()) -- moved to row 6 → line 7
    assert.equal(0, #notify_calls)
  end)

  it("review_next resolves float bufnr to source and sets cursor in source window", function()
    local source_bufnr = scratch(20)
    local discussions = {
      { id = "1", file = "a.lua", line = 3, resolved = false, comments = {} },
      { id = "2", file = "a.lua", line = 10, resolved = false, comments = {} },
    }
    local mappings = {
      ["1"] = { local_line = 3 },
      ["2"] = { local_line = 10 },
    }
    setup_review_stubs(
      { rel_path = "a.lua", vcs_info = { root = "/repo" } },
      { [source_bufnr] = { mappings = mappings } },
      discussions
    )

    local float_bufnr = vim.api.nvim_create_buf(false, true)
    stub_float(float_bufnr, source_bufnr)

    install_cmd_spy()
    set_cursor(1) -- above both discussions; _current_index = 0

    nav.review_next(float_bufnr)

    -- cur_idx=0 → target=(0%2)+1=1 → disc[1] = line 3
    assert.equal(3, cursor_row())
    assert.equal(0, #notify_calls)
    restore_cmd()
  end)

  it("review_prev resolves float bufnr to source and sets cursor in source window", function()
    local source_bufnr = scratch(20)
    local discussions = {
      { id = "1", file = "a.lua", line = 3, resolved = false, comments = {} },
      { id = "2", file = "a.lua", line = 10, resolved = false, comments = {} },
    }
    local mappings = {
      ["1"] = { local_line = 3 },
      ["2"] = { local_line = 10 },
    }
    setup_review_stubs(
      { rel_path = "a.lua", vcs_info = { root = "/repo" } },
      { [source_bufnr] = { mappings = mappings } },
      discussions
    )

    local float_bufnr = vim.api.nvim_create_buf(false, true)
    stub_float(float_bufnr, source_bufnr)

    install_cmd_spy()
    set_cursor(10) -- on disc 2; cur_idx = 2

    nav.review_prev(float_bufnr)

    -- cur_idx=2 > 1 → target=1 → disc[1] = line 3
    assert.equal(3, cursor_row())
    assert.equal(0, #notify_calls)
    restore_cmd()
  end)
end)
