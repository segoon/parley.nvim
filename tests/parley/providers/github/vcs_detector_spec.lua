--- Tests for parley.providers.github.vcs_detector — git VCS detection.
--- Run via: make test

local a = require("plenary.async").tests
local git_vcs = require("parley.providers.github.vcs_detector")

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
    assert(r, string.format("mock runner: unexpected call #%d", idx))
    return { code = r.code, stdout = r.stdout, stderr = r.stderr }
  end
  return { runner = runner, calls = calls }
end

--- Standard three-response sequence for a successful git probe.
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

a.describe("parley.providers.github.vcs_detector detect", function()
  a.before_each(function()
    original_runner = git_vcs._runner
  end)

  a.after_each(function()
    git_vcs._runner = original_runner
  end)

  a.it("returns nil when git rev-parse exits non-zero (not a git repo)", function()
    local mock = make_runner({
      { code = 128, stdout = "", stderr = "fatal: not a git repository" },
    })
    git_vcs._runner = mock.runner

    local result = git_vcs.detect("/some/random/path/file.lua")

    assert.is_nil(result)
  end)

  a.it("returns nil for an empty string path", function()
    local mock = make_runner({
      { code = 128, stdout = "", stderr = "fatal: not a git repository" },
    })
    git_vcs._runner = mock.runner

    local result = git_vcs.detect("")

    assert.is_nil(result)
  end)

  a.it("returns a VcsInfo table on success", function()
    local mock = make_runner(success_responses("/repo", "main", "https://github.com/org/repo.git"))
    git_vcs._runner = mock.runner

    local result = git_vcs.detect("/repo/src/foo.lua")

    assert.is_not_nil(result)
    assert.equals("table", type(result))
  end)

  a.it("vcs field is 'git'", function()
    local mock = make_runner(success_responses("/repo", "main", "https://github.com/org/repo.git"))
    git_vcs._runner = mock.runner

    local result = git_vcs.detect("/repo/src/foo.lua")

    assert.equals("git", result.vcs)
  end)

  a.it("root field equals trimmed stdout of rev-parse --show-toplevel", function()
    local mock = make_runner(success_responses("/my/project", "feat/x", "git@github.com:org/repo.git"))
    git_vcs._runner = mock.runner

    local result = git_vcs.detect("/my/project/src/mod.lua")

    assert.equals("/my/project", result.root)
  end)

  a.it("branch field equals trimmed stdout of rev-parse --abbrev-ref", function()
    local mock = make_runner(success_responses("/repo", "feature/awesome", "https://example.com/repo.git"))
    git_vcs._runner = mock.runner

    local result = git_vcs.detect("/repo/file.lua")

    assert.equals("feature/awesome", result.branch)
  end)

  a.it("remote_url is populated when git remote get-url origin succeeds", function()
    local mock = make_runner(success_responses("/repo", "main", "https://github.com/org/repo.git"))
    git_vcs._runner = mock.runner

    local result = git_vcs.detect("/repo/file.lua")

    assert.equals("https://github.com/org/repo.git", result.remote_url)
  end)

  a.it("remote_url is nil when git remote get-url origin exits non-zero", function()
    local mock = make_runner({
      { code = 0, stdout = "/repo\n", stderr = "" },
      { code = 0, stdout = "main\n", stderr = "" },
      { code = 2, stdout = "", stderr = "error: No such remote 'origin'" },
    })
    git_vcs._runner = mock.runner

    local result = git_vcs.detect("/repo/file.lua")

    assert.is_nil(result.remote_url)
  end)

  a.it("branch is nil when abbrev-ref returns literal 'HEAD' (detached)", function()
    local mock = make_runner({
      { code = 0, stdout = "/repo\n", stderr = "" },
      { code = 0, stdout = "HEAD\n", stderr = "" },
      { code = 0, stdout = "https://github.com/org/repo.git\n", stderr = "" },
    })
    git_vcs._runner = mock.runner

    local result = git_vcs.detect("/repo/file.lua")

    assert.is_nil(result.branch)
  end)

  a.it("branch is nil when abbrev-ref exits non-zero", function()
    local mock = make_runner({
      { code = 0, stdout = "/repo\n", stderr = "" },
      { code = 128, stdout = "", stderr = "fatal: no branch" },
      { code = 0, stdout = "https://github.com/org/repo.git\n", stderr = "" },
    })
    git_vcs._runner = mock.runner

    local result = git_vcs.detect("/repo/file.lua")

    assert.is_nil(result.branch)
  end)

  a.it("strips trailing newlines from root", function()
    local mock = make_runner({
      { code = 0, stdout = "/repo\n\n", stderr = "" },
      { code = 0, stdout = "main\n", stderr = "" },
      { code = 0, stdout = "https://github.com/org/repo.git\n", stderr = "" },
    })
    git_vcs._runner = mock.runner

    local result = git_vcs.detect("/repo/file.lua")

    assert.equals("/repo", result.root)
  end)

  a.it("first command is git rev-parse --show-toplevel", function()
    local mock = make_runner(success_responses("/repo", "main", "https://github.com/org/repo.git"))
    git_vcs._runner = mock.runner

    git_vcs.detect("/repo/file.lua")

    assert.same({ "git", "rev-parse", "--show-toplevel" }, mock.calls[1].cmd)
  end)

  a.it("second command is git rev-parse --abbrev-ref HEAD", function()
    local mock = make_runner(success_responses("/repo", "main", "https://github.com/org/repo.git"))
    git_vcs._runner = mock.runner

    git_vcs.detect("/repo/file.lua")

    assert.same({ "git", "rev-parse", "--abbrev-ref", "HEAD" }, mock.calls[2].cmd)
  end)

  a.it("third command is git remote get-url origin", function()
    local mock = make_runner(success_responses("/repo", "main", "https://github.com/org/repo.git"))
    git_vcs._runner = mock.runner

    git_vcs.detect("/repo/file.lua")

    assert.same({ "git", "remote", "get-url", "origin" }, mock.calls[3].cmd)
  end)

  a.it("first command cwd is parent directory of path", function()
    local mock = make_runner(success_responses("/repo", "main", "https://github.com/org/repo.git"))
    git_vcs._runner = mock.runner

    git_vcs.detect("/repo/src/deep/file.lua")

    assert.equals("/repo/src/deep", mock.calls[1].cwd)
  end)

  a.it("second and third commands use root as cwd", function()
    local mock = make_runner(success_responses("/repo", "main", "https://github.com/org/repo.git"))
    git_vcs._runner = mock.runner

    git_vcs.detect("/repo/src/file.lua")

    assert.equals("/repo", mock.calls[2].cwd)
    assert.equals("/repo", mock.calls[3].cwd)
  end)
end)
