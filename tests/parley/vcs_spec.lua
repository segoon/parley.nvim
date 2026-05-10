--- Tests for parley.vcs — VCS detection.
--- Run via: make test

local a = require("plenary.async").tests
local vcs = require("parley.vcs")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Build a synchronous mock runner that plays back a sequence of responses,
--- one per call, in order.  Each entry is `{ code, stdout, stderr }`.
---
--- Also records every call as `{ cmd, cwd }` in the `.calls` list so tests
--- can assert on what was invoked.
---
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

--- Standard three-response sequence for a fully-successful git probe.
--- stdout values include a trailing newline as real git produces.
---
--- @param root       string  Repo root path
--- @param branch     string  Branch name
--- @param remote_url string  Remote URL
--- @return { code: integer, stdout: string, stderr: string }[]
local function success_responses(root, branch, remote_url)
  return {
    { code = 0, stdout = root .. "\n", stderr = "" },
    { code = 0, stdout = branch .. "\n", stderr = "" },
    { code = 0, stdout = remote_url .. "\n", stderr = "" },
  }
end

-- ---------------------------------------------------------------------------
-- Test state
-- ---------------------------------------------------------------------------

local original_runner

-- ---------------------------------------------------------------------------
-- Suite
-- ---------------------------------------------------------------------------

a.describe("parley.vcs detect", function()
  a.before_each(function()
    original_runner = vcs._runner
  end)

  a.after_each(function()
    vcs._runner = original_runner
  end)

  -- -------------------------------------------------------------------------
  -- Returns nil when not in a git repo
  -- -------------------------------------------------------------------------

  a.it("returns nil when git rev-parse exits non-zero (not a git repo)", function()
    local mock = make_runner({
      { code = 128, stdout = "", stderr = "fatal: not a git repository" },
    })
    vcs._runner = mock.runner

    local result = vcs.detect("/some/random/path/file.lua")

    assert.is_nil(result)
  end)

  a.it("returns nil for an empty string path", function()
    local mock = make_runner({
      { code = 128, stdout = "", stderr = "fatal: not a git repository" },
    })
    vcs._runner = mock.runner

    local result = vcs.detect("")

    assert.is_nil(result)
  end)

  -- -------------------------------------------------------------------------
  -- Successful detection — shape of returned value
  -- -------------------------------------------------------------------------

  a.it("returns a table (VcsInfo) on success", function()
    local mock = make_runner(success_responses("/repo", "main", "https://github.com/org/repo.git"))
    vcs._runner = mock.runner

    local result = vcs.detect("/repo/src/foo.lua")

    assert.is_not_nil(result)
    assert.equals("table", type(result))
  end)

  a.it("vcs field is 'git'", function()
    local mock = make_runner(success_responses("/repo", "main", "https://github.com/org/repo.git"))
    vcs._runner = mock.runner

    local result = vcs.detect("/repo/src/foo.lua")

    assert.equals("git", result.vcs)
  end)

  a.it("root field equals trimmed stdout of rev-parse --show-toplevel", function()
    local mock = make_runner(success_responses("/my/project", "feat/x", "git@github.com:org/repo.git"))
    vcs._runner = mock.runner

    local result = vcs.detect("/my/project/src/mod.lua")

    assert.equals("/my/project", result.root)
  end)

  a.it("branch field equals trimmed stdout of rev-parse --abbrev-ref", function()
    local mock = make_runner(success_responses("/repo", "feature/awesome", "https://example.com/repo.git"))
    vcs._runner = mock.runner

    local result = vcs.detect("/repo/file.lua")

    assert.equals("feature/awesome", result.branch)
  end)

  a.it("remote_url field is populated when git remote get-url origin succeeds", function()
    local mock = make_runner(success_responses("/repo", "main", "https://github.com/org/repo.git"))
    vcs._runner = mock.runner

    local result = vcs.detect("/repo/file.lua")

    assert.equals("https://github.com/org/repo.git", result.remote_url)
  end)

  -- -------------------------------------------------------------------------
  -- remote_url nil cases
  -- -------------------------------------------------------------------------

  a.it("remote_url is nil when git remote get-url origin exits non-zero", function()
    local mock = make_runner({
      { code = 0, stdout = "/repo\n", stderr = "" },
      { code = 0, stdout = "main\n", stderr = "" },
      { code = 2, stdout = "", stderr = "error: No such remote 'origin'" },
    })
    vcs._runner = mock.runner

    local result = vcs.detect("/repo/file.lua")

    assert.is_nil(result.remote_url)
  end)

  -- -------------------------------------------------------------------------
  -- Detached HEAD
  -- -------------------------------------------------------------------------

  a.it("branch is nil when abbrev-ref returns literal 'HEAD' (detached)", function()
    local mock = make_runner({
      { code = 0, stdout = "/repo\n", stderr = "" },
      { code = 0, stdout = "HEAD\n", stderr = "" },
      { code = 0, stdout = "https://github.com/org/repo.git\n", stderr = "" },
    })
    vcs._runner = mock.runner

    local result = vcs.detect("/repo/file.lua")

    assert.is_nil(result.branch)
  end)

  a.it("branch is nil when abbrev-ref exits non-zero", function()
    local mock = make_runner({
      { code = 0, stdout = "/repo\n", stderr = "" },
      { code = 128, stdout = "", stderr = "fatal: no branch" },
      { code = 0, stdout = "https://github.com/org/repo.git\n", stderr = "" },
    })
    vcs._runner = mock.runner

    local result = vcs.detect("/repo/file.lua")

    assert.is_nil(result.branch)
  end)

  -- -------------------------------------------------------------------------
  -- Trailing newlines
  -- -------------------------------------------------------------------------

  a.it("strips trailing newlines from root", function()
    local mock = make_runner({
      { code = 0, stdout = "/repo\n\n", stderr = "" },
      { code = 0, stdout = "main\n", stderr = "" },
      { code = 0, stdout = "https://github.com/org/repo.git\n", stderr = "" },
    })
    vcs._runner = mock.runner

    local result = vcs.detect("/repo/file.lua")

    assert.equals("/repo", result.root)
  end)

  a.it("strips trailing newlines from branch", function()
    local mock = make_runner({
      { code = 0, stdout = "/repo\n", stderr = "" },
      { code = 0, stdout = "main\n\n", stderr = "" },
      { code = 0, stdout = "https://github.com/org/repo.git\n", stderr = "" },
    })
    vcs._runner = mock.runner

    local result = vcs.detect("/repo/file.lua")

    assert.equals("main", result.branch)
  end)

  a.it("strips trailing newlines from remote_url", function()
    local mock = make_runner({
      { code = 0, stdout = "/repo\n", stderr = "" },
      { code = 0, stdout = "main\n", stderr = "" },
      { code = 0, stdout = "https://github.com/org/repo.git\n\n", stderr = "" },
    })
    vcs._runner = mock.runner

    local result = vcs.detect("/repo/file.lua")

    assert.equals("https://github.com/org/repo.git", result.remote_url)
  end)

  -- -------------------------------------------------------------------------
  -- cwd routing
  -- -------------------------------------------------------------------------

  a.it("first command (rev-parse --show-toplevel) receives directory of path as cwd", function()
    local mock = make_runner(success_responses("/repo", "main", "https://github.com/org/repo.git"))
    vcs._runner = mock.runner

    vcs.detect("/repo/src/deep/file.lua")

    -- cwd for first call must be the parent directory of the file
    assert.equals("/repo/src/deep", mock.calls[1].cwd)
  end)

  a.it("second command (abbrev-ref) receives root as cwd", function()
    local mock = make_runner(success_responses("/repo", "main", "https://github.com/org/repo.git"))
    vcs._runner = mock.runner

    vcs.detect("/repo/src/file.lua")

    assert.equals("/repo", mock.calls[2].cwd)
  end)

  a.it("third command (remote get-url) receives root as cwd", function()
    local mock = make_runner(success_responses("/repo", "main", "https://github.com/org/repo.git"))
    vcs._runner = mock.runner

    vcs.detect("/repo/src/file.lua")

    assert.equals("/repo", mock.calls[3].cwd)
  end)

  -- -------------------------------------------------------------------------
  -- Command content
  -- -------------------------------------------------------------------------

  a.it("first command is git rev-parse --show-toplevel", function()
    local mock = make_runner(success_responses("/repo", "main", "https://github.com/org/repo.git"))
    vcs._runner = mock.runner

    vcs.detect("/repo/file.lua")

    assert.same({ "git", "rev-parse", "--show-toplevel" }, mock.calls[1].cmd)
  end)

  a.it("second command is git rev-parse --abbrev-ref HEAD", function()
    local mock = make_runner(success_responses("/repo", "main", "https://github.com/org/repo.git"))
    vcs._runner = mock.runner

    vcs.detect("/repo/file.lua")

    assert.same({ "git", "rev-parse", "--abbrev-ref", "HEAD" }, mock.calls[2].cmd)
  end)

  a.it("third command is git remote get-url origin", function()
    local mock = make_runner(success_responses("/repo", "main", "https://github.com/org/repo.git"))
    vcs._runner = mock.runner

    vcs.detect("/repo/file.lua")

    assert.same({ "git", "remote", "get-url", "origin" }, mock.calls[3].cmd)
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

    local result = vcs.check_sync_state("/repo", "src/foo.lua", SHA)

    assert.is_true(result.ok)
    assert.is_nil(result.err)
  end)

  -- ── Unpushed commits ──────────────────────────────────────────────────────

  a.it("returns ok=false when local HEAD differs from head_sha", function()
    local mock = make_runner({
      { code = 0, stdout = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n", stderr = "" },
    })
    vcs._runner = mock.runner

    local result = vcs.check_sync_state("/repo", "src/foo.lua", SHA)

    assert.is_false(result.ok)
    assert.is_not_nil(result.err)
    assert.is_truthy(result.err:find("push", 1, true))
  end)

  a.it("does not run status check when HEAD mismatches (short-circuits)", function()
    local mock = make_runner({
      { code = 0, stdout = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n", stderr = "" },
    })
    vcs._runner = mock.runner

    vcs.check_sync_state("/repo", "src/foo.lua", SHA)

    assert.equals(1, #mock.calls)
  end)

  -- ── Uncommitted changes ───────────────────────────────────────────────────

  a.it("returns ok=false when the file has uncommitted changes", function()
    local mock = make_runner({
      { code = 0, stdout = SHA .. "\n", stderr = "" },
      { code = 0, stdout = " M src/foo.lua\n", stderr = "" },
    })
    vcs._runner = mock.runner

    local result = vcs.check_sync_state("/repo", "src/foo.lua", SHA)

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

    local result = vcs.check_sync_state("/repo", "TODO.md", SHA)

    assert.is_truthy(result.err:find("TODO.md", 1, true))
  end)

  -- ── Command shape ─────────────────────────────────────────────────────────

  a.it("first command is git rev-parse HEAD with root as cwd", function()
    local mock = make_runner({
      { code = 0, stdout = SHA .. "\n", stderr = "" },
      { code = 0, stdout = "", stderr = "" },
    })
    vcs._runner = mock.runner

    vcs.check_sync_state("/my/repo", "foo.lua", SHA)

    assert.same({ "git", "rev-parse", "HEAD" }, mock.calls[1].cmd)
    assert.equals("/my/repo", mock.calls[1].cwd)
  end)

  a.it("second command is git status --porcelain -- <rel_path> with root as cwd", function()
    local mock = make_runner({
      { code = 0, stdout = SHA .. "\n", stderr = "" },
      { code = 0, stdout = "", stderr = "" },
    })
    vcs._runner = mock.runner

    vcs.check_sync_state("/my/repo", "src/bar.lua", SHA)

    assert.same({ "git", "status", "--porcelain", "--", "src/bar.lua" }, mock.calls[2].cmd)
    assert.equals("/my/repo", mock.calls[2].cwd)
  end)

  -- ── git failures ──────────────────────────────────────────────────────────

  a.it("returns ok=false when git rev-parse fails", function()
    local mock = make_runner({
      { code = 128, stdout = "", stderr = "fatal: not a git repo" },
    })
    vcs._runner = mock.runner

    local result = vcs.check_sync_state("/repo", "foo.lua", SHA)

    assert.is_false(result.ok)
    assert.is_not_nil(result.err)
  end)

  a.it("returns ok=false when git status fails", function()
    local mock = make_runner({
      { code = 0, stdout = SHA .. "\n", stderr = "" },
      { code = 128, stdout = "", stderr = "fatal: bad index" },
    })
    vcs._runner = mock.runner

    local result = vcs.check_sync_state("/repo", "foo.lua", SHA)

    assert.is_false(result.ok)
    assert.is_not_nil(result.err)
  end)
end)

-- ---------------------------------------------------------------------------
-- Suite: check_anchor_in_diff
-- ---------------------------------------------------------------------------

--- Build a simple unified diff with one hunk.
--- new_start/new_count define which lines on the new (RIGHT) side are changed.
---
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
    -- Hunk covers new lines 5–7 (new_start=5, new_count=3)
    local mock = make_runner({ { code = 0, stdout = diff_hunk(5, 3), stderr = "" } })
    vcs._runner = mock.runner

    local result = vcs.check_anchor_in_diff("/repo", "main", "f.lua", { start_line = 5, end_line = nil })

    assert.is_true(result.ok)
    assert.is_nil(result.err)
  end)

  a.it("returns ok=true for last line of hunk range", function()
    -- Hunk covers new lines 5–7; last valid line is 7
    local mock = make_runner({ { code = 0, stdout = diff_hunk(5, 3), stderr = "" } })
    vcs._runner = mock.runner

    local result = vcs.check_anchor_in_diff("/repo", "main", "f.lua", { start_line = 7, end_line = nil })

    assert.is_true(result.ok)
  end)

  a.it("returns ok=true for a multi-line anchor fully inside one hunk", function()
    -- Hunk covers new lines 10–14; anchor is 11–13
    local mock = make_runner({ { code = 0, stdout = diff_hunk(10, 5), stderr = "" } })
    vcs._runner = mock.runner

    local result = vcs.check_anchor_in_diff("/repo", "main", "f.lua", { start_line = 11, end_line = 13 })

    assert.is_true(result.ok)
  end)

  -- ── Line not in diff ──────────────────────────────────────────────────────

  a.it("returns ok=false when start_line is before the hunk", function()
    -- Hunk covers new lines 10–12; line 5 is outside
    local mock = make_runner({ { code = 0, stdout = diff_hunk(10, 3), stderr = "" } })
    vcs._runner = mock.runner

    local result = vcs.check_anchor_in_diff("/repo", "main", "f.lua", { start_line = 5, end_line = nil })

    assert.is_false(result.ok)
    assert.is_not_nil(result.err)
    assert.is_truthy(result.err:find("5", 1, true))
  end)

  a.it("returns ok=false when start_line is after the hunk", function()
    -- Hunk covers new lines 5–7; line 20 is outside
    local mock = make_runner({ { code = 0, stdout = diff_hunk(5, 3), stderr = "" } })
    vcs._runner = mock.runner

    local result = vcs.check_anchor_in_diff("/repo", "main", "f.lua", { start_line = 20, end_line = nil })

    assert.is_false(result.ok)
    assert.is_truthy(result.err:find("20", 1, true))
  end)

  a.it("error message mentions 'changed line'", function()
    local mock = make_runner({ { code = 0, stdout = diff_hunk(10, 3), stderr = "" } })
    vcs._runner = mock.runner

    local result = vcs.check_anchor_in_diff("/repo", "main", "f.lua", { start_line = 1, end_line = nil })

    assert.is_truthy(result.err:find("changed", 1, true))
  end)

  -- ── Multi-line anchor with end_line outside hunk ──────────────────────────

  a.it("returns ok=false when end_line is outside the hunk", function()
    -- Hunk covers new lines 10–12; end_line 15 is outside
    local mock = make_runner({ { code = 0, stdout = diff_hunk(10, 3), stderr = "" } })
    vcs._runner = mock.runner

    local result = vcs.check_anchor_in_diff("/repo", "main", "f.lua", { start_line = 10, end_line = 15 })

    assert.is_false(result.ok)
    assert.is_truthy(result.err:find("15", 1, true))
  end)

  -- ── No diff (file unchanged) ──────────────────────────────────────────────

  a.it("returns ok=false when git diff output is empty (file unchanged in PR)", function()
    local mock = make_runner({ { code = 0, stdout = "", stderr = "" } })
    vcs._runner = mock.runner

    local result = vcs.check_anchor_in_diff("/repo", "main", "unchanged.lua", { start_line = 1, end_line = nil })

    assert.is_false(result.ok)
    assert.is_truthy(result.err:find("unchanged.lua", 1, true))
  end)

  -- ── Git failure ───────────────────────────────────────────────────────────

  a.it("returns ok=true (allows through) when git diff fails", function()
    -- Unknown base branch or other git error: don't block the user.
    local mock = make_runner({ { code = 128, stdout = "", stderr = "fatal: unknown revision" } })
    vcs._runner = mock.runner

    local result = vcs.check_anchor_in_diff("/repo", "unknown-base", "f.lua", { start_line = 5, end_line = nil })

    assert.is_true(result.ok)
  end)

  -- ── Command shape ─────────────────────────────────────────────────────────

  a.it("runs git diff --unified=0 origin/<base_branch>...HEAD -- <rel_path>", function()
    local mock = make_runner({ { code = 0, stdout = diff_hunk(5, 3), stderr = "" } })
    vcs._runner = mock.runner

    vcs.check_anchor_in_diff("/my/repo", "main", "src/foo.lua", { start_line = 5, end_line = nil })

    local cmd = mock.calls[1].cmd
    assert.equals("git", cmd[1])
    assert.equals("diff", cmd[2])
    assert.equals("--unified=0", cmd[3])
    assert.equals("origin/main...HEAD", cmd[4])
    assert.equals("--", cmd[5])
    assert.equals("src/foo.lua", cmd[6])
    assert.equals("/my/repo", mock.calls[1].cwd)
  end)
end)
