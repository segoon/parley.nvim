local anchor = require("parley.anchor")
local function diff_with(hunk_header)
  return table.concat({
    "diff --git a/src/foo.lua b/src/foo.lua",
    "index abc123..def456 100644",
    "--- a/src/foo.lua",
    "+++ b/src/foo.lua",
    hunk_header,
    "-old line",
    "+new line",
  }, "\n") .. "\n"
end
local TWO_HUNK_DIFF = table.concat({
  "diff --git a/f.lua b/f.lua",
  "--- a/f.lua",
  "+++ b/f.lua",
  "@@ -5,2 +5,3 @@",
  "-a",
  "+b",
  "+c",
  "@@ -20,1 +21,1 @@",
  "-x",
  "+y",
}, "\n") .. "\n"

-- Suite: parse_hunks — pure unit tests
-- ---------------------------------------------------------------------------

describe("parley.anchor.parse_hunks", function()
  it("returns empty list for empty string", function()
    assert.same({}, anchor.parse_hunks(""))
  end)

  it("returns empty list for diff with no @@ lines", function()
    local diff = "diff --git a/f b/f\n--- a/f\n+++ b/f\n"
    assert.same({}, anchor.parse_hunks(diff))
  end)

  it("parses a standard hunk with both counts", function()
    local hunks = anchor.parse_hunks(diff_with("@@ -10,3 +10,5 @@"))
    assert.equals(1, #hunks)
    assert.equals(10, hunks[1].old_start)
    assert.equals(3, hunks[1].old_count)
    assert.equals(10, hunks[1].new_start)
    assert.equals(5, hunks[1].new_count)
  end)

  it("defaults old_count to 1 when omitted", function()
    local hunks = anchor.parse_hunks(diff_with("@@ -5 +5,2 @@"))
    assert.equals(1, hunks[1].old_count)
    assert.equals(2, hunks[1].new_count)
  end)

  it("defaults new_count to 1 when omitted", function()
    local hunks = anchor.parse_hunks(diff_with("@@ -5,2 +5 @@"))
    assert.equals(2, hunks[1].old_count)
    assert.equals(1, hunks[1].new_count)
  end)

  it("defaults both counts to 1 when both omitted", function()
    local hunks = anchor.parse_hunks(diff_with("@@ -5 +5 @@"))
    assert.equals(1, hunks[1].old_count)
    assert.equals(1, hunks[1].new_count)
  end)

  it("parses a pure insertion hunk (old_count=0)", function()
    local hunks = anchor.parse_hunks(diff_with("@@ -5,0 +6,3 @@"))
    assert.equals(0, hunks[1].old_count)
    assert.equals(3, hunks[1].new_count)
    assert.equals(5, hunks[1].old_start)
    assert.equals(6, hunks[1].new_start)
  end)

  it("parses a pure deletion hunk (new_count=0)", function()
    local hunks = anchor.parse_hunks(diff_with("@@ -5,3 +5,0 @@"))
    assert.equals(3, hunks[1].old_count)
    assert.equals(0, hunks[1].new_count)
  end)

  it("parses two hunks and returns them in order", function()
    local hunks = anchor.parse_hunks(TWO_HUNK_DIFF)
    assert.equals(2, #hunks)
    assert.equals(5, hunks[1].old_start)
    assert.equals(20, hunks[2].old_start)
  end)

  it("ignores +/- content lines and diff headers", function()
    -- Ensure lines starting with +, -, or 'diff' are not misparse as hunks.
    local diff = "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,1 +1,1 @@\n-old\n+new\n"
    local hunks = anchor.parse_hunks(diff)
    assert.equals(1, #hunks)
  end)
end)

-- ---------------------------------------------------------------------------
-- Suite: is_line_in_hunk — pure unit tests
-- ---------------------------------------------------------------------------

describe("parley.anchor.is_line_in_hunk", function()
  -- No hunks -----------------------------------------------------------------

  it("returns false when hunk list is empty", function()
    assert.is_false(anchor.is_line_in_hunk(1, {}))
  end)

  -- Single added-line hunk (new_count = 1) -----------------------------------

  it("returns true for the only line of a single-line hunk", function()
    -- @@ -5,1 +5,1 @@ — new region [5, 6)
    local hunks = { { old_start = 5, old_count = 1, new_start = 5, new_count = 1 } }
    assert.is_true(anchor.is_line_in_hunk(5, hunks))
  end)

  it("returns false for the line just before a hunk", function()
    local hunks = { { old_start = 5, old_count = 1, new_start = 5, new_count = 1 } }
    assert.is_false(anchor.is_line_in_hunk(4, hunks))
  end)

  it("returns false for the line just after a hunk", function()
    -- new region [5, 6) — line 6 is outside
    local hunks = { { old_start = 5, old_count = 1, new_start = 5, new_count = 1 } }
    assert.is_false(anchor.is_line_in_hunk(6, hunks))
  end)

  -- Multi-line hunk ----------------------------------------------------------

  it("returns true for first line of a multi-line hunk", function()
    local hunks = { { old_start = 10, old_count = 3, new_start = 10, new_count = 5 } }
    assert.is_true(anchor.is_line_in_hunk(10, hunks))
  end)

  it("returns true for last line of a multi-line hunk", function()
    -- new region [10, 15) — last line is 14
    local hunks = { { old_start = 10, old_count = 3, new_start = 10, new_count = 5 } }
    assert.is_true(anchor.is_line_in_hunk(14, hunks))
  end)

  it("returns true for a middle line of a multi-line hunk", function()
    local hunks = { { old_start = 10, old_count = 3, new_start = 10, new_count = 5 } }
    assert.is_true(anchor.is_line_in_hunk(12, hunks))
  end)

  it("returns false for the line immediately after a multi-line hunk", function()
    -- new region [10, 15) — line 15 is outside
    local hunks = { { old_start = 10, old_count = 3, new_start = 10, new_count = 5 } }
    assert.is_false(anchor.is_line_in_hunk(15, hunks))
  end)

  -- Pure deletion hunk (new_count = 0) ---------------------------------------

  it("returns false for any line when the only hunk is a pure deletion", function()
    -- new region [5, 5) — empty
    local hunks = { { old_start = 5, old_count = 3, new_start = 5, new_count = 0 } }
    assert.is_false(anchor.is_line_in_hunk(5, hunks))
    assert.is_false(anchor.is_line_in_hunk(6, hunks))
    assert.is_false(anchor.is_line_in_hunk(7, hunks))
  end)

  -- Pure insertion hunk ------------------------------------------------------

  it("returns true for inserted lines", function()
    -- @@ -5,0 +6,3 @@ — new region [6, 9)
    local hunks = { { old_start = 5, old_count = 0, new_start = 6, new_count = 3 } }
    assert.is_true(anchor.is_line_in_hunk(6, hunks))
    assert.is_true(anchor.is_line_in_hunk(7, hunks))
    assert.is_true(anchor.is_line_in_hunk(8, hunks))
  end)

  it("returns false for lines outside a pure insertion hunk", function()
    local hunks = { { old_start = 5, old_count = 0, new_start = 6, new_count = 3 } }
    assert.is_false(anchor.is_line_in_hunk(5, hunks))
    assert.is_false(anchor.is_line_in_hunk(9, hunks))
  end)

  -- Two hunks — line between them --------------------------------------------

  it("returns false for a line between two hunks", function()
    local hunks = {
      { old_start = 5, old_count = 1, new_start = 5, new_count = 1 },
      { old_start = 20, old_count = 1, new_start = 20, new_count = 1 },
    }
    assert.is_false(anchor.is_line_in_hunk(10, hunks))
  end)

  it("returns true for a line in the second of two hunks", function()
    local hunks = {
      { old_start = 5, old_count = 1, new_start = 5, new_count = 1 },
      { old_start = 20, old_count = 1, new_start = 20, new_count = 3 },
    }
    assert.is_true(anchor.is_line_in_hunk(21, hunks))
  end)
end)

-- ---------------------------------------------------------------------------
-- Suite: remap_line — pure unit tests
-- ---------------------------------------------------------------------------

describe("parley.anchor.remap_line", function()
  -- No hunks -----------------------------------------------------------------

  it("no hunks: maps to the same line", function()
    local r = anchor.remap_line(10, {})
    assert.equals(10, r.local_line)
    assert.equals(1.0, r.confidence)
    assert.is_false(r.stale)
  end)

  it("no hunks: pr_line=1 maps to 1", function()
    local r = anchor.remap_line(1, {})
    assert.equals(1, r.local_line)
  end)

  -- Line before hunk ---------------------------------------------------------

  it("line before the first hunk: same line (no offset yet)", function()
    local hunks = { { old_start = 10, old_count = 3, new_start = 10, new_count = 5 } }
    local r = anchor.remap_line(5, hunks)
    assert.equals(5, r.local_line)
    assert.equals(1.0, r.confidence)
    assert.is_false(r.stale)
  end)

  -- Line after hunk (offset) -------------------------------------------------

  it("line after a hunk with net +2: adds offset", function()
    -- hunk: old 10-12 (3 lines) → new 10-14 (5 lines), net +2
    local hunks = { { old_start = 10, old_count = 3, new_start = 10, new_count = 5 } }
    local r = anchor.remap_line(20, hunks)
    assert.equals(22, r.local_line)
    assert.equals(1.0, r.confidence)
    assert.is_false(r.stale)
  end)

  it("line after a hunk with net -1: subtracts offset", function()
    -- hunk: old 10-12 (3 lines) → new 10-11 (2 lines), net -1
    local hunks = { { old_start = 10, old_count = 3, new_start = 10, new_count = 2 } }
    local r = anchor.remap_line(20, hunks)
    assert.equals(19, r.local_line)
    assert.equals(1.0, r.confidence)
    assert.is_false(r.stale)
  end)

  -- Inside replacement hunk --------------------------------------------------

  it("line at old_start of replacement hunk: stale, maps to new_start", function()
    local hunks = { { old_start = 10, old_count = 3, new_start = 10, new_count = 2 } }
    local r = anchor.remap_line(10, hunks)
    assert.equals(10, r.local_line)
    assert.equals(0.0, r.confidence)
    assert.is_true(r.stale)
  end)

  it("line at last position inside replacement hunk: stale", function()
    -- old_start=10, old_count=3 → lines 10,11,12 are inside
    local hunks = { { old_start = 10, old_count = 3, new_start = 10, new_count = 2 } }
    local r = anchor.remap_line(12, hunks)
    assert.equals(10, r.local_line) -- maps to new_start
    assert.is_true(r.stale)
  end)

  it("line just after hunk (old_start + old_count): NOT stale, offset applied", function()
    -- old_start=10, old_count=3 → line 13 is the first line after the hunk
    local hunks = { { old_start = 10, old_count = 3, new_start = 10, new_count = 5 } }
    local r = anchor.remap_line(13, hunks)
    assert.equals(15, r.local_line) -- 13 + (5-3) = 15
    assert.is_false(r.stale)
  end)

  -- Inside pure deletion hunk ------------------------------------------------

  it("line inside pure deletion hunk: local_line is nil", function()
    local hunks = { { old_start = 10, old_count = 3, new_start = 10, new_count = 0 } }
    local r = anchor.remap_line(11, hunks)
    assert.is_nil(r.local_line)
    assert.equals(0.0, r.confidence)
    assert.is_true(r.stale)
  end)

  it("first line of pure deletion hunk: local_line is nil", function()
    local hunks = { { old_start = 10, old_count = 3, new_start = 10, new_count = 0 } }
    local r = anchor.remap_line(10, hunks)
    assert.is_nil(r.local_line)
    assert.is_true(r.stale)
  end)

  it("line after pure deletion hunk: offset is negative", function()
    -- net -3: lines 10,11,12 deleted
    local hunks = { { old_start = 10, old_count = 3, new_start = 10, new_count = 0 } }
    local r = anchor.remap_line(20, hunks)
    assert.equals(17, r.local_line) -- 20 + (0-3) = 17
    assert.is_false(r.stale)
  end)

  -- Pure insertion hunk ------------------------------------------------------

  it("pure insertion: line before insertion point: unchanged", function()
    -- @@ -5,0 +6,3 @@  → 3 lines inserted after old line 5; old_count=0
    local hunks = { { old_start = 5, old_count = 0, new_start = 6, new_count = 3 } }
    local r = anchor.remap_line(4, hunks)
    assert.equals(4, r.local_line)
    assert.is_false(r.stale)
  end)

  it("pure insertion: line after insertion point: offset += new_count", function()
    local hunks = { { old_start = 5, old_count = 0, new_start = 6, new_count = 3 } }
    local r = anchor.remap_line(6, hunks)
    assert.equals(9, r.local_line) -- 6 + 3 = 9
    assert.is_false(r.stale)
  end)

  it("pure insertion: pr_line = old_start is NOT inside hunk (old_count=0)", function()
    -- The match range [5, 5+0) = [5, 5) is empty, so line 5 is NOT captured.
    local hunks = { { old_start = 5, old_count = 0, new_start = 6, new_count = 3 } }
    local r = anchor.remap_line(5, hunks)
    assert.is_false(r.stale)
    -- Unified diff insertion coordinates identify the preceding old line.
    assert.equals(5, r.local_line)
  end)

  -- Two hunks, cumulative offset ---------------------------------------------

  it("two hunks: cumulative offset applied correctly", function()
    -- hunk1: old 5-6 (2) → new 5-7 (3), net +1
    -- hunk2: old 20-20 (1) → new 21-22 (2), net +1
    -- Line 25 should be shifted by +2 total.
    local hunks = {
      { old_start = 5, old_count = 2, new_start = 5, new_count = 3 },
      { old_start = 20, old_count = 1, new_start = 21, new_count = 2 },
    }
    local r = anchor.remap_line(25, hunks)
    assert.equals(27, r.local_line)
    assert.is_false(r.stale)
  end)

  it("two hunks: line between them gets only first hunk's offset", function()
    local hunks = {
      { old_start = 5, old_count = 2, new_start = 5, new_count = 3 }, -- net +1
      { old_start = 20, old_count = 1, new_start = 21, new_count = 2 }, -- net +1
    }
    local r = anchor.remap_line(10, hunks)
    assert.equals(11, r.local_line) -- 10 + 1
    assert.is_false(r.stale)
  end)
end)
