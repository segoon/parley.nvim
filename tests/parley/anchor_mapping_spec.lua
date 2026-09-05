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
  local function runner(info, revision, file)
    table.insert(calls, { cmd = { info, revision, file }, cwd = info.root })
    return stdout
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
  local function runner(info, revision, file)
    table.insert(calls, { cmd = { info, revision, file }, cwd = info.root })
    return by_file[file] or ""
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

-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- Suite: map_line — async, injected runner
-- ---------------------------------------------------------------------------

a.describe("parley.anchor.map_line", function()
  local orig_runner

  a.before_each(function()
    orig_runner = anchor._diff
  end)

  a.after_each(function()
    anchor._diff = orig_runner
  end)

  a.it("passes VCS context, revision and file to content mapping", function()
    local mock = make_runner("")
    anchor._diff = mock.runner

    anchor.map_line({ vcs = "git", root = "/repo" }, "abc123", "src/foo.lua", 10)

    assert.equals(1, #mock.calls)
    local cmd = mock.calls[1].cmd
    assert.same({ vcs = "git", root = "/repo" }, cmd[1])
    assert.equals("abc123", cmd[2])
    assert.equals("src/foo.lua", cmd[3])
  end)

  a.it("passes repo_root as cwd", function()
    local mock = make_runner("")
    anchor._diff = mock.runner

    anchor.map_line({ vcs = "git", root = "/my/repo" }, "abc123", "src/foo.lua", 10)

    assert.equals("/my/repo", mock.calls[1].cwd)
  end)

  a.it("returns confidence=1.0 and local_line=pr_line when diff is empty", function()
    local mock = make_runner("")
    anchor._diff = mock.runner

    local result = anchor.map_line({ vcs = "git", root = "/repo" }, "abc123", "src/foo.lua", 15)

    assert.equals(15, result.local_line)
    assert.equals(1.0, result.confidence)
    assert.is_false(result.stale)
  end)

  a.it("returns stale=true when pr_line falls inside a replacement hunk", function()
    local diff = diff_with("@@ -10,3 +10,2 @@")
    local mock = make_runner(diff)
    anchor._diff = mock.runner

    local result = anchor.map_line({ vcs = "git", root = "/repo" }, "abc123", "src/foo.lua", 11)

    assert.is_true(result.stale)
    assert.equals(0.0, result.confidence)
    assert.equals(10, result.local_line)
  end)

  a.it("returns local_line=nil when pr_line falls inside a pure deletion hunk", function()
    local diff = diff_with("@@ -10,3 +10,0 @@")
    local mock = make_runner(diff)
    anchor._diff = mock.runner

    local result = anchor.map_line({ vcs = "git", root = "/repo" }, "abc123", "src/foo.lua", 11)

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
    orig_runner = anchor._diff
  end)

  a.after_each(function()
    anchor._diff = orig_runner
  end)

  a.it("returns empty table for empty discussions list", function()
    local mock = make_runner("")
    anchor._diff = mock.runner

    local result = anchor.map_discussions({ vcs = "git", root = "/repo" }, "abc123", {})

    assert.same({}, result)
    assert.equals(0, #mock.calls)
  end)

  a.it("result is keyed by discussion.id", function()
    local mock = make_runner("")
    anchor._diff = mock.runner
    local discussions = { make_discussion("d1", "a.lua", 5) }

    local result = anchor.map_discussions({ vcs = "git", root = "/repo" }, "abc123", discussions)

    assert.is_not_nil(result["d1"])
  end)

  a.it("two discussions on the same file produce one content read", function()
    local mock = make_runner("")
    anchor._diff = mock.runner
    local discussions = {
      make_discussion("d1", "src/foo.lua", 5),
      make_discussion("d2", "src/foo.lua", 20),
    }

    anchor.map_discussions({ vcs = "git", root = "/repo" }, "abc123", discussions)

    assert.equals(1, #mock.calls)
  end)

  a.it("two discussions on different files produce two content reads", function()
    local mock = make_file_runner({ ["src/foo.lua"] = "", ["src/bar.lua"] = "" })
    anchor._diff = mock.runner
    local discussions = {
      make_discussion("d1", "src/foo.lua", 5),
      make_discussion("d2", "src/bar.lua", 10),
    }

    anchor.map_discussions({ vcs = "git", root = "/repo" }, "abc123", discussions)

    assert.equals(2, #mock.calls)
  end)

  a.it("discussion with no diff gets confidence=1.0 and local_line=pr_line", function()
    local mock = make_runner("")
    anchor._diff = mock.runner
    local discussions = { make_discussion("d1", "src/foo.lua", 7) }

    local result = anchor.map_discussions({ vcs = "git", root = "/repo" }, "abc123", discussions)

    assert.equals(7, result["d1"].local_line)
    assert.equals(1.0, result["d1"].confidence)
    assert.is_false(result["d1"].stale)
  end)

  a.it("correctly maps two discussions on the same file through a shared hunk", function()
    -- hunk: old lines 10-12 replaced → net offset +1 after line 12
    local diff = diff_with("@@ -10,3 +10,4 @@")
    local mock = make_runner(diff)
    anchor._diff = mock.runner
    local discussions = {
      make_discussion("before", "src/foo.lua", 5), -- before hunk
      make_discussion("after", "src/foo.lua", 15), -- after hunk
    }

    local result = anchor.map_discussions({ vcs = "git", root = "/repo" }, "abc123", discussions)

    -- Line 5 is before the hunk: no offset.
    assert.equals(5, result["before"].local_line)
    assert.is_false(result["before"].stale)
    -- Line 15 is after the hunk with net +1: 15+1=16.
    assert.equals(16, result["after"].local_line)
    assert.is_false(result["after"].stale)
  end)

  a.it("single-line discussion has nil local_end_line", function()
    local mock = make_runner("")
    anchor._diff = mock.runner
    local discussions = { make_discussion("d1", "src/foo.lua", 7) }

    local result = anchor.map_discussions({ vcs = "git", root = "/repo" }, "abc123", discussions)

    assert.equals(7, result["d1"].local_line)
    assert.is_nil(result["d1"].local_end_line)
  end)

  a.it("multi-line discussion outside hunks gets shifted local_end_line", function()
    -- Hunk before the range adds +2 lines.
    local diff = diff_with("@@ -2,1 +2,3 @@")
    local mock = make_runner(diff)
    anchor._diff = mock.runner
    local discussions = { make_discussion("d1", "src/foo.lua", 10, 14) }

    local result = anchor.map_discussions({ vcs = "git", root = "/repo" }, "abc123", discussions)

    assert.equals(12, result["d1"].local_line) -- 10 + 2
    assert.equals(16, result["d1"].local_end_line) -- 14 + 2
  end)

  a.it("multi-line discussion with end_line in a deletion hunk gets nil local_end_line", function()
    -- Pure deletion at lines 14-15.
    local diff = diff_with("@@ -14,2 +14,0 @@")
    local mock = make_runner(diff)
    anchor._diff = mock.runner
    local discussions = { make_discussion("d1", "src/foo.lua", 10, 14) }

    local result = anchor.map_discussions({ vcs = "git", root = "/repo" }, "abc123", discussions)

    assert.equals(10, result["d1"].local_line)
    assert.is_nil(result["d1"].local_end_line)
  end)

  a.it("stale discussion on one file does not affect result on another file", function()
    local mock = make_file_runner({
      ["a.lua"] = diff_with("@@ -5,2 +5,0 @@"), -- pure deletion at lines 5-6
      ["b.lua"] = "",
    })
    anchor._diff = mock.runner
    local discussions = {
      make_discussion("d_stale", "a.lua", 5),
      make_discussion("d_clean", "b.lua", 5),
    }

    local result = anchor.map_discussions({ vcs = "git", root = "/repo" }, "abc123", discussions)

    assert.is_nil(result["d_stale"].local_line)
    assert.is_true(result["d_stale"].stale)
    assert.equals(5, result["d_clean"].local_line)
    assert.is_false(result["d_clean"].stale)
  end)
end)
