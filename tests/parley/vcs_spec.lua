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
      { code = 0, stdout = "",          stderr = "" },
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
      { code = 0, stdout = SHA .. "\n",    stderr = "" },
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
      { code = 0, stdout = SHA .. "\n",      stderr = "" },
      { code = 0, stdout = "M  TODO.md\n",   stderr = "" },
    })
    vcs._runner = mock.runner

    local result = vcs.check_sync_state("/repo", "TODO.md", SHA)

    assert.is_truthy(result.err:find("TODO.md", 1, true))
  end)

  -- ── Command shape ─────────────────────────────────────────────────────────

  a.it("first command is git rev-parse HEAD with root as cwd", function()
    local mock = make_runner({
      { code = 0, stdout = SHA .. "\n", stderr = "" },
      { code = 0, stdout = "",          stderr = "" },
    })
    vcs._runner = mock.runner

    vcs.check_sync_state("/my/repo", "foo.lua", SHA)

    assert.same({ "git", "rev-parse", "HEAD" }, mock.calls[1].cmd)
    assert.equals("/my/repo", mock.calls[1].cwd)
  end)

  a.it("second command is git status --porcelain -- <rel_path> with root as cwd", function()
    local mock = make_runner({
      { code = 0, stdout = SHA .. "\n", stderr = "" },
      { code = 0, stdout = "",          stderr = "" },
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
      { code = 0,   stdout = SHA .. "\n", stderr = "" },
      { code = 128, stdout = "",          stderr = "fatal: bad index" },
    })
    vcs._runner = mock.runner

    local result = vcs.check_sync_state("/repo", "foo.lua", SHA)

    assert.is_false(result.ok)
    assert.is_not_nil(result.err)
  end)
end)
