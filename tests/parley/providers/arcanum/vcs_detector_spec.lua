--- Tests for parley.providers.arcanum.vcs_detector — Arc VCS detection.
--- Run via: make test

local a = require("plenary.async").tests
local arc_vcs = require("parley.providers.arcanum.vcs_detector")

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

local original_runner

-- ---------------------------------------------------------------------------
-- Suite
-- ---------------------------------------------------------------------------

a.describe("parley.providers.arcanum.vcs_detector detect", function()
  a.before_each(function()
    original_runner = arc_vcs._runner
  end)

  a.after_each(function()
    arc_vcs._runner = original_runner
  end)

  a.it("returns nil when arc root exits non-zero", function()
    local mock = make_runner({
      { code = 1, stdout = "", stderr = "Not a mounted arc repository" },
    })
    arc_vcs._runner = mock.runner

    local result = arc_vcs.detect("/some/path/file.lua")

    assert.is_nil(result)
  end)

  a.it("returns nil when arc root returns empty stdout", function()
    local mock = make_runner({
      { code = 0, stdout = "\n", stderr = "" },
    })
    arc_vcs._runner = mock.runner

    local result = arc_vcs.detect("/some/path/file.lua")

    assert.is_nil(result)
  end)

  a.it("returns VcsInfo on success", function()
    local mock = make_runner({
      { code = 0, stdout = "/home/segoon/arcadia4\n", stderr = "" },
      {
        code = 0,
        stdout = table.concat({
          '{"remote":"users/segoon/feature/chaotic-const",',
          '"user_login":"segoon","branch":"feature/chaotic-const"}\n',
        }),
        stderr = "",
      },
    })
    arc_vcs._runner = mock.runner

    local result = arc_vcs.detect("/home/segoon/arcadia4/taxi/uservices/userver/chaotic/ya.make")

    assert.is_not_nil(result)
    assert.equals("arc", result.vcs)
    assert.equals("/home/segoon/arcadia4", result.root)
    assert.equals("users/segoon/feature/chaotic-const", result.branch)
    assert.equals("arc://segoon", result.remote_url)
  end)

  a.it("extracts remote branch id from arc info output", function()
    local mock = make_runner({
      { code = 0, stdout = "/arcadia\n", stderr = "" },
      { code = 0, stdout = '{"remote":"users/me/feature","user_login":"me"}\n', stderr = "" },
    })
    arc_vcs._runner = mock.runner

    local result = arc_vcs.detect("/arcadia/path/file.lua")

    assert.equals("users/me/feature", result.branch)
  end)

  a.it("branch is nil when arc info exits non-zero", function()
    local mock = make_runner({
      { code = 0, stdout = "/arcadia\n", stderr = "" },
      { code = 1, stdout = "", stderr = "info failed" },
    })
    arc_vcs._runner = mock.runner

    local result = arc_vcs.detect("/arcadia/path/file.lua")

    assert.is_nil(result.branch)
  end)

  a.it("branch is nil when remote is missing", function()
    local mock = make_runner({
      { code = 0, stdout = "/arcadia\n", stderr = "" },
      { code = 0, stdout = '{"branch":"feature/x","user_login":"me"}\n', stderr = "" },
    })
    arc_vcs._runner = mock.runner

    local result = arc_vcs.detect("/arcadia/path/file.lua")

    assert.is_nil(result.branch)
  end)

  a.it("extracts login from user_login in arc info", function()
    local mock = make_runner({
      { code = 0, stdout = "/arcadia\n", stderr = "" },
      { code = 0, stdout = '{"remote":"users/vasya/feature/x","user_login":"vasya"}\n', stderr = "" },
    })
    arc_vcs._runner = mock.runner

    local result = arc_vcs.detect("/arcadia/path/file.lua")

    assert.equals("arc://vasya", result.remote_url)
  end)

  a.it("remote_url is nil when user_login is not present", function()
    local mock = make_runner({
      { code = 0, stdout = "/arcadia\n", stderr = "" },
      { code = 0, stdout = '{"remote":"users/me/feature/x"}\n', stderr = "" },
    })
    arc_vcs._runner = mock.runner

    local result = arc_vcs.detect("/arcadia/path/file.lua")

    assert.is_nil(result.remote_url)
  end)

  a.it("runs arc root with file parent directory as cwd", function()
    local mock = make_runner({
      { code = 0, stdout = "/arcadia\n", stderr = "" },
      { code = 0, stdout = '{"remote":"users/me/feature/x","user_login":"me"}\n', stderr = "" },
    })
    arc_vcs._runner = mock.runner

    arc_vcs.detect("/arcadia/taxi/uservices/userver/chaotic/ya.make")

    assert.equals("/arcadia/taxi/uservices/userver/chaotic", mock.calls[1].cwd)
    assert.same({ "arc", "root" }, mock.calls[1].cmd)
  end)

  a.it("runs arc info --json with repo root as cwd", function()
    local mock = make_runner({
      { code = 0, stdout = "/arcadia\n", stderr = "" },
      { code = 0, stdout = '{"remote":"users/me/feature/x","user_login":"me"}\n', stderr = "" },
    })
    arc_vcs._runner = mock.runner

    arc_vcs.detect("/arcadia/path/file.lua")

    assert.same({ "arc", "info", "--json" }, mock.calls[2].cmd)
    assert.equals("/arcadia", mock.calls[2].cwd)
  end)

  a.it("returns nil when arc info json is invalid", function()
    local mock = make_runner({
      { code = 0, stdout = "/arcadia\n", stderr = "" },
      { code = 0, stdout = "not json\n", stderr = "" },
    })
    arc_vcs._runner = mock.runner

    local result = arc_vcs.detect("/arcadia/path/file.lua")

    assert.is_nil(result.branch)
    assert.is_nil(result.remote_url)
  end)
end)
