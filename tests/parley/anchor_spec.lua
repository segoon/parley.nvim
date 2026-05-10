--- Tests for parley.anchor — line anchoring engine.
--- Run via: make test

local a = require("plenary.async").tests
local anchor = require("parley.anchor")
local model = require("parley.model")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Build a mock runner that returns a fixed diff output.
--- Records calls in .calls list: { cmd, cwd }.
---
--- @param stdout string  Simulated git diff output
--- @return table  { runner, calls }
local function make_runner(stdout)
  local calls = {}
  local function runner(cmd, cwd)
    table.insert(calls, { cmd = cmd, cwd = cwd })
    return { code = 0, stdout = stdout, stderr = "" }
  end
  return { runner = runner, calls = calls }
end

--- Build a runner that returns different outputs for different files.
--- Keyed by the last element of the command (the file path after "--").
---
--- @param by_file table<string, string>  file → diff stdout
--- @return table  { runner, calls }
local function make_file_runner(by_file)
  local calls = {}
  local function runner(cmd, cwd)
    table.insert(calls, { cmd = cmd, cwd = cwd })
    -- The file argument is the last element of the command.
    local file = cmd[#cmd]
    local stdout = by_file[file] or ""
    return { code = 0, stdout = stdout, stderr = "" }
  end
  return { runner = runner, calls = calls }
end

--- Minimal valid discussion anchored at a given file and line.
---
--- @param id       string
--- @param file     string
--- @param line     integer
--- @param end_line integer|nil  Optional end of multi-line range
--- @return parley.Discussion
local function make_discussion(id, file, line, end_line)
  local comment = model.new_comment({
    id = id .. "-c",
    author = "alice",
    body = model.new_body({ text = "hi", format = "markdown" }),
    created_at = "2024-01-01T00:00:00Z",
    updated_at = "2024-01-01T00:00:00Z",
  })
  return model.new_discussion({
    id = id,
    file = file,
    line = line,
    end_line = end_line,
    comments = { comment },
  })
end

--- Unified diff snippet for a single hunk.  The surrounding file headers are
--- included so parse_hunks has realistic input to skip over.
---
--- @param hunk_header string  e.g. "@@ -10,3 +10,5 @@"
--- @return string
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

--- Two-hunk diff snippet.
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

-- ---------------------------------------------------------------------------
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
    -- Line 5 is "after" the insertion (old_start=5, empty range), gets +3 offset.
    assert.equals(8, r.local_line)
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

-- ---------------------------------------------------------------------------
-- Suite: map_line — async, injected runner
-- ---------------------------------------------------------------------------

a.describe("parley.anchor.map_line", function()
  local orig_runner

  a.before_each(function()
    orig_runner = anchor._runner
  end)

  a.after_each(function()
    anchor._runner = orig_runner
  end)

  a.it("calls git diff with --unified=0, base_commit, and file", function()
    local mock = make_runner("")
    anchor._runner = mock.runner

    anchor.map_line("/repo", "abc123", "src/foo.lua", 10)

    assert.equals(1, #mock.calls)
    local cmd = mock.calls[1].cmd
    assert.equals("git", cmd[1])
    assert.equals("diff", cmd[2])
    assert.equals("--unified=0", cmd[3])
    assert.equals("abc123", cmd[4])
    assert.equals("--", cmd[5])
    assert.equals("src/foo.lua", cmd[6])
  end)

  a.it("passes repo_root as cwd", function()
    local mock = make_runner("")
    anchor._runner = mock.runner

    anchor.map_line("/my/repo", "abc123", "src/foo.lua", 10)

    assert.equals("/my/repo", mock.calls[1].cwd)
  end)

  a.it("returns confidence=1.0 and local_line=pr_line when diff is empty", function()
    local mock = make_runner("")
    anchor._runner = mock.runner

    local result = anchor.map_line("/repo", "abc123", "src/foo.lua", 15)

    assert.equals(15, result.local_line)
    assert.equals(1.0, result.confidence)
    assert.is_false(result.stale)
  end)

  a.it("returns stale=true when pr_line falls inside a replacement hunk", function()
    local diff = diff_with("@@ -10,3 +10,2 @@")
    local mock = make_runner(diff)
    anchor._runner = mock.runner

    local result = anchor.map_line("/repo", "abc123", "src/foo.lua", 11)

    assert.is_true(result.stale)
    assert.equals(0.0, result.confidence)
    assert.equals(10, result.local_line)
  end)

  a.it("returns local_line=nil when pr_line falls inside a pure deletion hunk", function()
    local diff = diff_with("@@ -10,3 +10,0 @@")
    local mock = make_runner(diff)
    anchor._runner = mock.runner

    local result = anchor.map_line("/repo", "abc123", "src/foo.lua", 11)

    assert.is_nil(result.local_line)
    assert.is_true(result.stale)
  end)
end)

-- ---------------------------------------------------------------------------
-- Suite: map_discussions — async, injected runner
-- ---------------------------------------------------------------------------

a.describe("parley.anchor.map_discussions", function()
  local orig_runner

  a.before_each(function()
    orig_runner = anchor._runner
  end)

  a.after_each(function()
    anchor._runner = orig_runner
  end)

  a.it("returns empty table for empty discussions list", function()
    local mock = make_runner("")
    anchor._runner = mock.runner

    local result = anchor.map_discussions("/repo", "abc123", {})

    assert.same({}, result)
    assert.equals(0, #mock.calls)
  end)

  a.it("result is keyed by discussion.id", function()
    local mock = make_runner("")
    anchor._runner = mock.runner
    local discussions = { make_discussion("d1", "a.lua", 5) }

    local result = anchor.map_discussions("/repo", "abc123", discussions)

    assert.is_not_nil(result["d1"])
  end)

  a.it("two discussions on the same file produce one git call", function()
    local mock = make_runner("")
    anchor._runner = mock.runner
    local discussions = {
      make_discussion("d1", "src/foo.lua", 5),
      make_discussion("d2", "src/foo.lua", 20),
    }

    anchor.map_discussions("/repo", "abc123", discussions)

    assert.equals(1, #mock.calls)
  end)

  a.it("two discussions on different files produce two git calls", function()
    local mock = make_file_runner({ ["src/foo.lua"] = "", ["src/bar.lua"] = "" })
    anchor._runner = mock.runner
    local discussions = {
      make_discussion("d1", "src/foo.lua", 5),
      make_discussion("d2", "src/bar.lua", 10),
    }

    anchor.map_discussions("/repo", "abc123", discussions)

    assert.equals(2, #mock.calls)
  end)

  a.it("discussion with no diff gets confidence=1.0 and local_line=pr_line", function()
    local mock = make_runner("")
    anchor._runner = mock.runner
    local discussions = { make_discussion("d1", "src/foo.lua", 7) }

    local result = anchor.map_discussions("/repo", "abc123", discussions)

    assert.equals(7, result["d1"].local_line)
    assert.equals(1.0, result["d1"].confidence)
    assert.is_false(result["d1"].stale)
  end)

  a.it("correctly maps two discussions on the same file through a shared hunk", function()
    -- hunk: old lines 10-12 replaced → net offset +1 after line 12
    local diff = diff_with("@@ -10,3 +10,4 @@")
    local mock = make_runner(diff)
    anchor._runner = mock.runner
    local discussions = {
      make_discussion("before", "src/foo.lua", 5), -- before hunk
      make_discussion("after", "src/foo.lua", 15), -- after hunk
    }

    local result = anchor.map_discussions("/repo", "abc123", discussions)

    -- Line 5 is before the hunk: no offset.
    assert.equals(5, result["before"].local_line)
    assert.is_false(result["before"].stale)
    -- Line 15 is after the hunk with net +1: 15+1=16.
    assert.equals(16, result["after"].local_line)
    assert.is_false(result["after"].stale)
  end)

  a.it("single-line discussion has nil local_end_line", function()
    local mock = make_runner("")
    anchor._runner = mock.runner
    local discussions = { make_discussion("d1", "src/foo.lua", 7) }

    local result = anchor.map_discussions("/repo", "abc123", discussions)

    assert.equals(7, result["d1"].local_line)
    assert.is_nil(result["d1"].local_end_line)
  end)

  a.it("multi-line discussion outside hunks gets shifted local_end_line", function()
    -- Hunk before the range adds +2 lines.
    local diff = diff_with("@@ -2,1 +2,3 @@")
    local mock = make_runner(diff)
    anchor._runner = mock.runner
    local discussions = { make_discussion("d1", "src/foo.lua", 10, 14) }

    local result = anchor.map_discussions("/repo", "abc123", discussions)

    assert.equals(12, result["d1"].local_line) -- 10 + 2
    assert.equals(16, result["d1"].local_end_line) -- 14 + 2
  end)

  a.it("multi-line discussion with end_line in a deletion hunk gets nil local_end_line", function()
    -- Pure deletion at lines 14-15.
    local diff = diff_with("@@ -14,2 +14,0 @@")
    local mock = make_runner(diff)
    anchor._runner = mock.runner
    local discussions = { make_discussion("d1", "src/foo.lua", 10, 14) }

    local result = anchor.map_discussions("/repo", "abc123", discussions)

    assert.equals(10, result["d1"].local_line)
    assert.is_nil(result["d1"].local_end_line)
  end)

  a.it("stale discussion on one file does not affect result on another file", function()
    local mock = make_file_runner({
      ["a.lua"] = diff_with("@@ -5,2 +5,0 @@"), -- pure deletion at lines 5-6
      ["b.lua"] = "",
    })
    anchor._runner = mock.runner
    local discussions = {
      make_discussion("d_stale", "a.lua", 5),
      make_discussion("d_clean", "b.lua", 5),
    }

    local result = anchor.map_discussions("/repo", "abc123", discussions)

    assert.is_nil(result["d_stale"].local_line)
    assert.is_true(result["d_stale"].stale)
    assert.equals(5, result["d_clean"].local_line)
    assert.is_false(result["d_clean"].stale)
  end)
end)
