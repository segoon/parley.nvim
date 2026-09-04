--- Tests for parley.vcs — VCS detection dispatcher and git helpers.
--- Run via: make test

local a = require("plenary.async").tests
local vcs = require("parley.vcs")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Build a synchronous mock runner that plays back a sequence of responses.
--- @param responses { code: integer, stdout: string, stderr: string }[]
--- @return { runner: fun(cmd: string[], cwd: string): table, calls: table[] }
local function make_runner(responses)
  local idx = 0
  local calls = {}
  local function runner(cmd, cwd)
    idx = idx + 1
    table.insert(calls, { cmd = cmd, cwd = cwd })
    local r = responses[idx]
    assert(r, string.format("mock runner: unexpected call #%d (only %d responses configured)", idx, #responses))
    return { code = r.code, stdout = r.stdout, stderr = r.stderr }
  end
  return { runner = runner, calls = calls }
end

-- ---------------------------------------------------------------------------
-- Test state
-- ---------------------------------------------------------------------------

local original_runner
local original_detectors

-- ---------------------------------------------------------------------------
-- Suite: dispatcher (register_detector / detect)
-- ---------------------------------------------------------------------------

a.describe("parley.vcs dispatcher", function()
  a.before_each(function()
    original_detectors = vcs.registered_detectors()
    vcs.reset_detectors()
  end)

  a.after_each(function()
    vcs.reset_detectors()
    for _, d in ipairs(original_detectors) do
      vcs.register_detector(d.name, d.fn)
    end
  end)

  a.it("returns nil when no detectors are registered", function()
    local result = vcs.detect("/some/path/file.lua")
    assert.is_nil(result)
  end)

  a.it("calls registered detector with the path", function()
    local received_path = nil
    vcs.register_detector("test", function(path)
      received_path = path
      return nil
    end)

    vcs.detect("/my/file.lua")

    assert.equals("/my/file.lua", received_path)
  end)

  a.it("returns first non-nil result", function()
    vcs.register_detector("first", function(_path)
      return nil
    end)
    vcs.register_detector("second", function(_path)
      return { vcs = "git", root = "/repo", branch = "main", remote_url = nil }
    end)
    vcs.register_detector("third", function(_path)
      return { vcs = "other", root = "/other", branch = nil, remote_url = nil }
    end)

    local result = vcs.detect("/some/file.lua")

    assert.equals("git", result.vcs)
  end)

  a.it("stops at first non-nil result (does not call later detectors)", function()
    local third_called = false
    vcs.register_detector("first", function(_path)
      return { vcs = "git", root = "/repo", branch = "main", remote_url = nil }
    end)
    vcs.register_detector("second", function(_path)
      third_called = true
      return nil
    end)

    vcs.detect("/file.lua")

    assert.is_false(third_called)
  end)

  a.it("tries detectors in registration order", function()
    local order = {}
    vcs.register_detector("alpha", function(_path)
      table.insert(order, "alpha")
      return nil
    end)
    vcs.register_detector("beta", function(_path)
      table.insert(order, "beta")
      return nil
    end)
    vcs.register_detector("gamma", function(_path)
      table.insert(order, "gamma")
      return nil
    end)

    vcs.detect("/file.lua")

    assert.same({ "alpha", "beta", "gamma" }, order)
  end)

  a.it("reset_detectors removes all detectors", function()
    vcs.register_detector("test", function(_path)
      return { vcs = "test", root = "/", branch = nil, remote_url = nil }
    end)
    vcs.reset_detectors()

    local result = vcs.detect("/file.lua")

    assert.is_nil(result)
  end)

  a.it("register_detector raises for empty name", function()
    assert.has_error(function()
      vcs.register_detector("", function() end)
    end)
  end)

  a.it("register_detector raises for non-function fn", function()
    assert.has_error(function()
      vcs.register_detector("test", "not-a-function")
    end)
  end)

  a.it("registered_detectors returns a copy in order", function()
    vcs.register_detector("a", function() end)
    vcs.register_detector("b", function() end)

    local detectors = vcs.registered_detectors()

    assert.equals(2, #detectors)
    assert.equals("a", detectors[1].name)
    assert.equals("b", detectors[2].name)
  end)
end)

-- ---------------------------------------------------------------------------
-- Suite: check_sync_state
-- ---------------------------------------------------------------------------

a.describe("parley.vcs check_sync_state", function()
  local SHA = "aabbccddeeff00112233445566778899aabbccdd"

  a.before_each(function()
    original_runner = vcs._runner
  end)

  a.after_each(function()
    vcs._runner = original_runner
  end)

  -- ── Happy path ────────────────────────────────────────────────────────────

  a.it("returns ok=true when HEAD matches head_sha and file is clean", function()
    local mock = make_runner({
      { code = 0, stdout = SHA .. "\n", stderr = "" },
      { code = 0, stdout = "", stderr = "" },
    })
    vcs._runner = mock.runner

    local result = vcs.check_sync_state({ vcs = "git", root = "/repo" }, "src/foo.lua", SHA)

    assert.is_true(result.ok)
    assert.is_nil(result.err)
  end)

  -- ── Unpushed commits ──────────────────────────────────────────────────────

  a.it("returns ok=false when local HEAD differs from head_sha", function()
    local mock = make_runner({
      { code = 0, stdout = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n", stderr = "" },
    })
    vcs._runner = mock.runner

    local result = vcs.check_sync_state({ vcs = "git", root = "/repo" }, "src/foo.lua", SHA)

    assert.is_false(result.ok)
    assert.is_not_nil(result.err)
    assert.is_truthy(result.err:find("differs", 1, true))
  end)

  a.it("does not run status check when HEAD mismatches (short-circuits)", function()
    local mock = make_runner({
      { code = 0, stdout = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n", stderr = "" },
    })
    vcs._runner = mock.runner

    vcs.check_sync_state({ vcs = "git", root = "/repo" }, "src/foo.lua", SHA)

    assert.equals(1, #mock.calls)
  end)

  -- ── Uncommitted changes ───────────────────────────────────────────────────

  a.it("returns ok=false when the file has uncommitted changes", function()
    local mock = make_runner({
      { code = 0, stdout = SHA .. "\n", stderr = "" },
      { code = 0, stdout = " M src/foo.lua\n", stderr = "" },
    })
    vcs._runner = mock.runner

    local result = vcs.check_sync_state({ vcs = "git", root = "/repo" }, "src/foo.lua", SHA)

    assert.is_false(result.ok)
    assert.is_not_nil(result.err)
    assert.is_truthy(result.err:find("uncommitted", 1, true))
  end)

  a.it("error message includes the rel_path for uncommitted changes", function()
    local mock = make_runner({
      { code = 0, stdout = SHA .. "\n", stderr = "" },
      { code = 0, stdout = "M  TODO.md\n", stderr = "" },
    })
    vcs._runner = mock.runner

    local result = vcs.check_sync_state({ vcs = "git", root = "/repo" }, "TODO.md", SHA)

    assert.is_truthy(result.err:find("TODO.md", 1, true))
  end)

  -- ── Command shape ─────────────────────────────────────────────────────────

  a.it("first command is git rev-parse HEAD with root as cwd", function()
    local mock = make_runner({
      { code = 0, stdout = SHA .. "\n", stderr = "" },
      { code = 0, stdout = "", stderr = "" },
    })
    vcs._runner = mock.runner

    vcs.check_sync_state({ vcs = "git", root = "/my/repo" }, "foo.lua", SHA)

    assert.same({ "git", "rev-parse", "HEAD" }, mock.calls[1].cmd)
    assert.equals("/my/repo", mock.calls[1].cwd)
  end)

  a.it("second command is git status --porcelain -- <rel_path> with root as cwd", function()
    local mock = make_runner({
      { code = 0, stdout = SHA .. "\n", stderr = "" },
      { code = 0, stdout = "", stderr = "" },
    })
    vcs._runner = mock.runner

    vcs.check_sync_state({ vcs = "git", root = "/my/repo" }, "src/bar.lua", SHA)

    assert.same({ "git", "status", "--porcelain", "--", "src/bar.lua" }, mock.calls[2].cmd)
    assert.equals("/my/repo", mock.calls[2].cwd)
  end)

  -- ── git failures ──────────────────────────────────────────────────────────

  a.it("returns ok=false when git rev-parse fails", function()
    local mock = make_runner({
      { code = 128, stdout = "", stderr = "fatal: not a git repo" },
    })
    vcs._runner = mock.runner

    local result = vcs.check_sync_state({ vcs = "git", root = "/repo" }, "foo.lua", SHA)

    assert.is_false(result.ok)
    assert.is_not_nil(result.err)
  end)

  a.it("returns ok=false when git status fails", function()
    local mock = make_runner({
      { code = 0, stdout = SHA .. "\n", stderr = "" },
      { code = 128, stdout = "", stderr = "fatal: bad index" },
    })
    vcs._runner = mock.runner

    local result = vcs.check_sync_state({ vcs = "git", root = "/repo" }, "foo.lua", SHA)

    assert.is_false(result.ok)
    assert.is_not_nil(result.err)
  end)
end)

-- ---------------------------------------------------------------------------
-- Suite: check_anchor_in_diff
-- ---------------------------------------------------------------------------

--- Build a simple unified diff with one hunk.
--- @param new_start integer
--- @param new_count integer
--- @return string
local function diff_hunk(new_start, new_count)
  return string.format(
    "diff --git a/f.lua b/f.lua\n--- a/f.lua\n+++ b/f.lua\n@@ -1,%d +%d,%d @@\n",
    new_count,
    new_start,
    new_count
  )
end

a.describe("parley.vcs check_anchor_in_diff", function()
  a.before_each(function()
    original_runner = vcs._runner
  end)

  a.after_each(function()
    vcs._runner = original_runner
  end)

  -- ── Happy path: line inside hunk ─────────────────────────────────────────

  a.it("returns ok=true when start_line is inside a diff hunk", function()
    local mock = make_runner({ { code = 0, stdout = diff_hunk(5, 3), stderr = "" } })
    vcs._runner = mock.runner

    local result = vcs.check_anchor_in_diff(
      { vcs = "git", root = "/repo" },
      "main",
      "f.lua",
      { start_line = 5, end_line = nil }
    )

    assert.is_true(result.ok)
    assert.is_nil(result.err)
  end)

  a.it("returns ok=true for last line of hunk range", function()
    local mock = make_runner({ { code = 0, stdout = diff_hunk(5, 3), stderr = "" } })
    vcs._runner = mock.runner

    local result = vcs.check_anchor_in_diff(
      { vcs = "git", root = "/repo" },
      "main",
      "f.lua",
      { start_line = 7, end_line = nil }
    )

    assert.is_true(result.ok)
  end)

  a.it("returns ok=true for a multi-line anchor fully inside one hunk", function()
    local mock = make_runner({ { code = 0, stdout = diff_hunk(10, 5), stderr = "" } })
    vcs._runner = mock.runner

    local result = vcs.check_anchor_in_diff(
      { vcs = "git", root = "/repo" },
      "main",
      "f.lua",
      { start_line = 11, end_line = 13 }
    )

    assert.is_true(result.ok)
  end)

  -- ── Line not in diff ──────────────────────────────────────────────────────

  a.it("returns ok=false when start_line is before the hunk", function()
    local mock = make_runner({ { code = 0, stdout = diff_hunk(10, 3), stderr = "" } })
    vcs._runner = mock.runner

    local result = vcs.check_anchor_in_diff(
      { vcs = "git", root = "/repo" },
      "main",
      "f.lua",
      { start_line = 5, end_line = nil }
    )

    assert.is_false(result.ok)
    assert.is_not_nil(result.err)
    assert.is_truthy(result.err:find("5", 1, true))
  end)

  a.it("returns ok=false when start_line is after the hunk", function()
    local mock = make_runner({ { code = 0, stdout = diff_hunk(5, 3), stderr = "" } })
    vcs._runner = mock.runner

    local result = vcs.check_anchor_in_diff(
      { vcs = "git", root = "/repo" },
      "main",
      "f.lua",
      { start_line = 20, end_line = nil }
    )

    assert.is_false(result.ok)
    assert.is_truthy(result.err:find("20", 1, true))
  end)

  a.it("error message mentions 'changed line'", function()
    local mock = make_runner({ { code = 0, stdout = diff_hunk(10, 3), stderr = "" } })
    vcs._runner = mock.runner

    local result = vcs.check_anchor_in_diff(
      { vcs = "git", root = "/repo" },
      "main",
      "f.lua",
      { start_line = 1, end_line = nil }
    )

    assert.is_truthy(result.err:find("changed", 1, true))
  end)

  -- ── Multi-line anchor with end_line outside hunk ──────────────────────────

  a.it("returns ok=false when end_line is outside the hunk", function()
    local mock = make_runner({ { code = 0, stdout = diff_hunk(10, 3), stderr = "" } })
    vcs._runner = mock.runner

    local result = vcs.check_anchor_in_diff(
      { vcs = "git", root = "/repo" },
      "main",
      "f.lua",
      { start_line = 10, end_line = 15 }
    )

    assert.is_false(result.ok)
    assert.is_truthy(result.err:find("13", 1, true))
  end)

  -- ── No diff (file unchanged) ──────────────────────────────────────────────

  a.it("returns ok=false when git diff output is empty (file unchanged in PR)", function()
    local mock = make_runner({ { code = 0, stdout = "", stderr = "" } })
    vcs._runner = mock.runner

    local result = vcs.check_anchor_in_diff(
      { vcs = "git", root = "/repo" },
      "main",
      "unchanged.lua",
      { start_line = 1, end_line = nil }
    )

    assert.is_false(result.ok)
    assert.is_truthy(result.err:find("unchanged.lua", 1, true))
  end)

  -- ── Git failure ───────────────────────────────────────────────────────────

  a.it("returns ok=false when Git diff fails", function()
    local mock = make_runner({ { code = 128, stdout = "", stderr = "fatal: unknown revision" } })
    vcs._runner = mock.runner

    local result = vcs.check_anchor_in_diff(
      { vcs = "git", root = "/repo" },
      "unknown-base",
      "f.lua",
      { start_line = 5, end_line = nil }
    )

    assert.is_false(result.ok)
  end)

  -- ── Command shape ─────────────────────────────────────────────────────────

  a.it("runs git diff --unified=0 origin/<base_branch>...HEAD -- <rel_path>", function()
    local mock = make_runner({ { code = 0, stdout = diff_hunk(5, 3), stderr = "" } })
    vcs._runner = mock.runner

    vcs.check_anchor_in_diff(
      { vcs = "git", root = "/my/repo" },
      "main",
      "src/foo.lua",
      { start_line = 5, end_line = nil }
    )

    local cmd = mock.calls[1].cmd
    assert.equals("git", cmd[1])
    assert.equals("diff", cmd[2])
    assert.equals("--unified=0", cmd[5])
    assert.equals("origin/main...HEAD", cmd[6])
    assert.equals("--", cmd[7])
    assert.equals("src/foo.lua", cmd[8])
    assert.equals("/my/repo", mock.calls[1].cwd)
  end)
end)
