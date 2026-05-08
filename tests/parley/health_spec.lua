--- Tests for parley.health.
--- Run via: make test

local health = require("parley.health")

--- @return table, table[]
local function make_health_sink()
  local reports = {}
  local sink = {}

  function sink.start(message)
    reports[#reports + 1] = { kind = "start", message = message }
  end

  function sink.ok(message)
    reports[#reports + 1] = { kind = "ok", message = message }
  end

  function sink.info(message)
    reports[#reports + 1] = { kind = "info", message = message }
  end

  function sink.warn(message)
    reports[#reports + 1] = { kind = "warn", message = message }
  end

  function sink.error(message)
    reports[#reports + 1] = { kind = "error", message = message }
  end

  return sink, reports
end

--- @param reports table[]
--- @param kind string
--- @param pattern string
local function assert_report(reports, kind, pattern)
  for _, report in ipairs(reports) do
    if report.kind == kind and report.message:find(pattern, 1, true) then
      return
    end
  end

  error(string.format("expected %s report containing %q", kind, pattern))
end

describe("parley.health.check", function()
  local saved_health
  local saved_has_nvim_010
  local saved_require
  local saved_executable
  local saved_get_parley
  local saved_isdirectory
  local saved_filewritable
  local saved_current_buf
  local saved_get_buf_props
  local saved_run
  local saved_read_github_token
  local saved_parse_remote_url

  before_each(function()
    saved_health = health._health
    saved_has_nvim_010 = health._has_nvim_010
    saved_require = health._require
    saved_executable = health._executable
    saved_get_parley = health._get_parley
    saved_isdirectory = health._isdirectory
    saved_filewritable = health._filewritable
    saved_current_buf = health._current_buf
    saved_get_buf_props = health._get_buf_props
    saved_run = health._run
    saved_read_github_token = health._read_github_token
    saved_parse_remote_url = health._parse_remote_url
  end)

  after_each(function()
    health._health = saved_health
    health._has_nvim_010 = saved_has_nvim_010
    health._require = saved_require
    health._executable = saved_executable
    health._get_parley = saved_get_parley
    health._isdirectory = saved_isdirectory
    health._filewritable = saved_filewritable
    health._current_buf = saved_current_buf
    health._get_buf_props = saved_get_buf_props
    health._run = saved_run
    health._read_github_token = saved_read_github_token
    health._parse_remote_url = saved_parse_remote_url
  end)

  it("reports a healthy GitHub setup", function()
    local sink, reports = make_health_sink()
    health._health = sink
    health._has_nvim_010 = function()
      return true
    end
    health._require = function(name)
      if name == "plenary.async" or name == "telescope" or name == "render-markdown" then
        return { loaded = name }
      end
      error("unexpected require: " .. name)
    end
    health._executable = function(bin)
      return bin == "git" or bin == "gh"
    end
    health._get_parley = function()
      return {
        config = {
          cache_dir = "/tmp/parley-cache",
          telescope = true,
        },
      }
    end
    health._isdirectory = function(path)
      return path == "/tmp/parley-cache"
    end
    health._filewritable = function(path)
      return path == "/tmp/parley-cache"
    end
    health._current_buf = function()
      return 7
    end
    health._get_buf_props = function(bufnr)
      assert.equals(7, bufnr)
      return {
        name = "/repo/lua/parley/init.lua",
        buftype = "",
        filetype = "lua",
      }
    end
    health._run = function(cmd, cwd)
      if cmd[1] == "git" and cmd[2] == "rev-parse" and cmd[3] == "--show-toplevel" then
        assert.equals("/repo/lua/parley", cwd)
        return { code = 0, stdout = "/repo\n", stderr = "" }
      end
      if cmd[1] == "git" and cmd[2] == "rev-parse" and cmd[3] == "--abbrev-ref" then
        assert.equals("/repo", cwd)
        return { code = 0, stdout = "feature/health\n", stderr = "" }
      end
      if cmd[1] == "git" and cmd[2] == "remote" then
        assert.equals("/repo", cwd)
        return { code = 0, stdout = "https://github.com/owner/repo.git\n", stderr = "" }
      end
      error("unexpected command")
    end
    health._parse_remote_url = function(url)
      assert.equals("https://github.com/owner/repo.git", url)
      return { host = "github.com", owner = "owner", repo = "repo" }
    end
    health._read_github_token = function(host)
      assert.equals("github.com", host)
      return "ghp_test", nil
    end

    health.check()

    assert_report(reports, "ok", "Neovim >= 0.10")
    assert_report(reports, "ok", "plenary.async is installed")
    assert_report(reports, "ok", "git executable found")
    assert_report(reports, "ok", "gh executable found")
    assert_report(reports, "ok", "parley.setup() has been called")
    assert_report(reports, "ok", "cache_dir exists and is writable")
    assert_report(reports, "ok", "telescope.nvim is installed")
    assert_report(reports, "ok", "render-markdown.nvim is installed")
    assert_report(reports, "ok", "current buffer is in git repository: /repo")
    assert_report(reports, "ok", "current branch: feature/health")
    assert_report(reports, "ok", "origin remote: https://github.com/owner/repo.git")
    assert_report(reports, "ok", "GitHub provider matches current repository")
    assert_report(reports, "ok", "GitHub authentication token resolved for github.com")
  end)

  it("reports missing required runtime dependencies", function()
    local sink, reports = make_health_sink()
    health._health = sink
    health._has_nvim_010 = function()
      return false
    end
    health._require = function(_name)
      error("module not found")
    end
    health._executable = function(_bin)
      return false
    end
    health._get_parley = function()
      return { config = nil }
    end
    health._isdirectory = function(_path)
      return false
    end
    health._filewritable = function(_path)
      return false
    end
    health._current_buf = function()
      return 1
    end
    health._get_buf_props = function(_bufnr)
      return {
        name = "",
        buftype = "nofile",
        filetype = "",
      }
    end

    health.check()

    assert_report(reports, "error", "Neovim >= 0.10 is required")
    assert_report(reports, "error", "plenary.async is not installed")
    assert_report(reports, "error", "git executable not found")
    assert_report(reports, "error", "gh executable not found")
    assert_report(reports, "warn", "parley.setup() has not been called")
    assert_report(reports, "info", "current buffer buftype=nofile is not a regular file buffer")
  end)

  it("warns when telescope is enabled but missing", function()
    local sink, reports = make_health_sink()
    health._health = sink
    health._has_nvim_010 = function()
      return true
    end
    health._require = function(name)
      if name == "plenary.async" then
        return {}
      end
      error("module not found")
    end
    health._executable = function(_bin)
      return true
    end
    health._get_parley = function()
      return {
        config = {
          cache_dir = "/tmp/parley-cache",
          telescope = true,
        },
      }
    end
    health._isdirectory = function(_path)
      return false
    end
    health._filewritable = function(_path)
      return false
    end
    health._current_buf = function()
      return 1
    end
    health._get_buf_props = function(_bufnr)
      return {
        name = "",
        buftype = "",
        filetype = "",
      }
    end

    health.check()

    assert_report(reports, "warn", "telescope.nvim is enabled in Parley config but not installed")
    assert_report(reports, "info", "render-markdown.nvim is not installed")
  end)

  it("reports non-repository file buffers without warning", function()
    local sink, reports = make_health_sink()
    health._health = sink
    health._has_nvim_010 = function()
      return true
    end
    health._require = function(name)
      if name == "plenary.async" then
        return {}
      end
      error("module not found")
    end
    health._executable = function(bin)
      return bin == "git" or bin == "gh"
    end
    health._get_parley = function()
      return { config = nil }
    end
    health._current_buf = function()
      return 4
    end
    health._get_buf_props = function(_bufnr)
      return {
        name = "/tmp/file.lua",
        buftype = "",
        filetype = "lua",
      }
    end
    health._run = function(cmd, cwd)
      assert.same({ "git", "rev-parse", "--show-toplevel" }, cmd)
      assert.equals("/tmp", cwd)
      return { code = 128, stdout = "", stderr = "fatal: not a git repository" }
    end

    health.check()

    assert_report(reports, "info", "current buffer is not in a git repository")
  end)

  it("warns for unsupported current repository remotes", function()
    local sink, reports = make_health_sink()
    health._health = sink
    health._has_nvim_010 = function()
      return true
    end
    health._require = function(name)
      if name == "plenary.async" then
        return {}
      end
      error("module not found")
    end
    health._executable = function(bin)
      return bin == "git" or bin == "gh"
    end
    health._get_parley = function()
      return { config = nil }
    end
    health._current_buf = function()
      return 5
    end
    health._get_buf_props = function(_bufnr)
      return {
        name = "/repo/file.lua",
        buftype = "",
        filetype = "lua",
      }
    end
    health._run = function(cmd, cwd)
      if cmd[3] == "--show-toplevel" then
        assert.equals("/repo", cwd)
        return { code = 0, stdout = "/repo\n", stderr = "" }
      end
      if cmd[3] == "--abbrev-ref" then
        return { code = 0, stdout = "main\n", stderr = "" }
      end
      return { code = 0, stdout = "https://gitlab.com/owner/repo.git\n", stderr = "" }
    end
    health._parse_remote_url = function(url)
      assert.equals("https://gitlab.com/owner/repo.git", url)
      return { host = "gitlab.com", owner = "owner", repo = "repo" }
    end

    health.check()

    assert_report(reports, "warn", "current repository host gitlab.com is not supported yet")
  end)

  it("warns when GitHub auth cannot be resolved", function()
    local sink, reports = make_health_sink()
    health._health = sink
    health._has_nvim_010 = function()
      return true
    end
    health._require = function(name)
      if name == "plenary.async" then
        return {}
      end
      error("module not found")
    end
    health._executable = function(bin)
      return bin == "git" or bin == "gh"
    end
    health._get_parley = function()
      return { config = nil }
    end
    health._current_buf = function()
      return 6
    end
    health._get_buf_props = function(_bufnr)
      return {
        name = "/repo/file.lua",
        buftype = "",
        filetype = "lua",
      }
    end
    health._run = function(cmd, _cwd)
      if cmd[3] == "--show-toplevel" then
        return { code = 0, stdout = "/repo\n", stderr = "" }
      end
      if cmd[3] == "--abbrev-ref" then
        return { code = 0, stdout = "main\n", stderr = "" }
      end
      return { code = 0, stdout = "https://github.com/owner/repo.git\n", stderr = "" }
    end
    health._parse_remote_url = function(_url)
      return { host = "github.com", owner = "owner", repo = "repo" }
    end
    health._read_github_token = function(host)
      assert.equals("github.com", host)
      return nil, "cannot read hosts.yml"
    end

    health.check()

    assert_report(reports, "warn", "GitHub auth is not configured for github.com")
  end)
end)
