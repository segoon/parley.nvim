--- tests/parley/providers/github/transport_spec.lua
--- Tests for gh availability probe and fast-fail guards.

local transport = require("parley.providers.github.transport")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local saved = {}

local function save_seams()
  saved.gh_available = transport._gh_available
  saved.executable = transport._executable
  saved.notify = vim.notify
end

local function restore_seams()
  transport._gh_available = saved.gh_available
  transport._executable = saved.executable
  vim.notify = saved.notify
end

--- Stub vim.notify and return the recorded calls table.
--- @return table[]
local function stub_notify()
  local calls = {}
  vim.notify = function(msg, level)
    table.insert(calls, { msg = msg, level = level })
  end
  return calls
end

--- Build a minimal provider table for transport functions.
--- @param opts? table  optional overrides for _runner, _spawn, _sleep, _defer, config
--- @return table
local function make_provider(opts)
  opts = opts or {}
  return {
    _runner = opts._runner or function(_cmd)
      return { code = 0, stdout = "[]", stderr = "" }
    end,
    _spawn = opts._spawn or function(_cmd, callback)
      callback({ code = 0, stdout = "[]", stderr = "" })
      return { kill = function() end }
    end,
    _sleep = opts._sleep or function(_ms) end,
    _defer = opts._defer or function(cb, _ms)
      cb()
      return nil
    end,
    _config = require("parley.providers.github.config").resolve(opts.config or { retry_count = 0 }),
  }
end

-- ---------------------------------------------------------------------------
-- Suite: probe_gh_executable
-- ---------------------------------------------------------------------------

describe("parley.providers.github.transport — probe_gh_executable", function()
  before_each(save_seams)
  after_each(restore_seams)

  it("sets _gh_available = true when gh is found", function()
    transport._executable = function(_bin)
      return 1
    end
    transport._gh_available = nil

    transport.probe_gh_executable()

    assert.is_true(transport._gh_available)
  end)

  it("sets _gh_available = false when gh is not found", function()
    transport._executable = function(_bin)
      return 0
    end
    transport._gh_available = nil

    transport.probe_gh_executable()

    assert.is_false(transport._gh_available)
  end)

  it("updates _gh_available from false to true when gh becomes available", function()
    transport._gh_available = false
    transport._executable = function(_bin)
      return 1
    end

    transport.probe_gh_executable()

    assert.is_true(transport._gh_available)
  end)
end)

-- ---------------------------------------------------------------------------
-- Suite: gh_run — fast-fail guard
-- ---------------------------------------------------------------------------

describe("parley.providers.github.transport — gh_run availability guard", function()
  before_each(save_seams)
  after_each(restore_seams)

  it("raises a clean error without calling runner when gh is not found after re-probe", function()
    transport._gh_available = false
    transport._executable = function(_bin)
      return 0 -- still not found on re-probe
    end

    local runner_called = false
    local provider = make_provider({
      _runner = function(_cmd)
        runner_called = true
        return { code = 0, stdout = "[]", stderr = "" }
      end,
    })

    local notify_calls = stub_notify()
    local ok, err = pcall(transport.gh_run, provider, { "gh", "api", "/user" })

    assert.is_false(ok)
    assert.is_false(runner_called)
    -- Error message must be the clean user-facing string, not a Lua traceback
    assert.is_not_nil(err:find("'gh'", 1, true))
    assert.is_not_nil(err:find("not found", 1, true))
    -- Must NOT contain a Lua file:line prefix
    assert.is_nil(err:find("transport%.lua", 1, true))
    -- vim.notify(WARN) must fire
    assert.equals(1, #notify_calls)
    assert.is_not_nil(notify_calls[1].msg:find("'gh'", 1, true))
    assert.equals(vim.log.levels.WARN, notify_calls[1].level)
  end)

  it("calls runner normally when gh is not found on initial probe but found on re-probe", function()
    transport._gh_available = false
    transport._executable = function(_bin)
      return 1 -- found on re-probe
    end

    local runner_called = false
    local provider = make_provider({
      _runner = function(_cmd)
        runner_called = true
        return { code = 0, stdout = "[]", stderr = "" }
      end,
    })

    local ok, _ = pcall(transport.gh_run, provider, { "gh", "api", "/user" })

    assert.is_true(ok)
    assert.is_true(runner_called)
    -- State updated to true after successful re-probe
    assert.is_true(transport._gh_available)
  end)

  it("does not re-probe when _gh_available is already true", function()
    transport._gh_available = true
    local probe_calls = 0
    transport._executable = function(_bin)
      probe_calls = probe_calls + 1
      return 1
    end

    local provider = make_provider({
      _runner = function(_cmd)
        return { code = 0, stdout = "[]", stderr = "" }
      end,
    })

    pcall(transport.gh_run, provider, { "gh", "api", "/user" })

    assert.equals(0, probe_calls)
  end)
end)

-- ---------------------------------------------------------------------------
-- Suite: gh_start — fast-fail guard
-- ---------------------------------------------------------------------------

describe("parley.providers.github.transport — gh_start availability guard", function()
  before_each(save_seams)
  after_each(restore_seams)

  it("calls callback with ok=false and clean error when gh is not found after re-probe", function()
    transport._gh_available = false
    transport._executable = function(_bin)
      return 0 -- still not found on re-probe
    end

    local spawn_called = false
    local provider = make_provider({
      _spawn = function(_cmd, _callback)
        spawn_called = true
        return { kill = function() end }
      end,
    })

    local notify_calls = stub_notify()
    local result = nil
    transport.gh_start(provider, { "gh", "api", "/user" }, function(r)
      result = r
    end)

    -- Allow any vim.schedule flush
    vim.wait(50, function()
      return result ~= nil
    end)

    assert.is_not_nil(result)
    assert.is_false(result.ok)
    assert.is_false(spawn_called)
    -- Error message must be the clean user-facing string
    assert.is_not_nil(result.err:find("'gh'", 1, true))
    assert.is_not_nil(result.err:find("not found", 1, true))
    assert.is_nil(result.err:find("transport%.lua", 1, true))
    -- vim.notify(WARN) must fire
    assert.equals(1, #notify_calls)
    assert.is_not_nil(notify_calls[1].msg:find("'gh'", 1, true))
    assert.equals(vim.log.levels.WARN, notify_calls[1].level)
  end)

  it("calls spawn normally when gh is not found on initial probe but found on re-probe", function()
    transport._gh_available = false
    transport._executable = function(_bin)
      return 1 -- found on re-probe
    end

    local spawn_called = false
    local provider = make_provider({
      _spawn = function(_cmd, callback)
        spawn_called = true
        callback({ code = 0, stdout = "[]", stderr = "" })
        return { kill = function() end }
      end,
    })

    local result = nil
    transport.gh_start(provider, { "gh", "api", "/user" }, function(r)
      result = r
    end)

    vim.wait(50, function()
      return result ~= nil
    end)

    assert.is_true(spawn_called)
    assert.is_true(transport._gh_available)
  end)

  it("does not re-probe when _gh_available is already true", function()
    transport._gh_available = true
    local probe_calls = 0
    transport._executable = function(_bin)
      probe_calls = probe_calls + 1
      return 1
    end

    local provider = make_provider({
      _spawn = function(_cmd, callback)
        callback({ code = 0, stdout = "[]", stderr = "" })
        return { kill = function() end }
      end,
    })

    local done = false
    transport.gh_start(provider, { "gh", "api", "/user" }, function(_r)
      done = true
    end)

    vim.wait(50, function()
      return done
    end)

    assert.equals(0, probe_calls)
  end)
end)

-- ---------------------------------------------------------------------------
-- Suite: fetch_viewer_login — gh availability guard
-- ---------------------------------------------------------------------------

describe("parley.providers.github.transport — fetch_viewer_login availability guard", function()
  before_each(save_seams)
  after_each(restore_seams)

  it("calls vim.notify(WARN) and skips runner when gh is not found", function()
    transport._gh_available = false
    transport._executable = function(_bin)
      return 0 -- still not found on re-probe
    end

    local runner_called = false
    local provider = make_provider({
      _runner = function(_cmd)
        runner_called = true
        return { code = 0, stdout = "", stderr = "" }
      end,
    })
    provider._viewer_login = nil

    local notify_calls = stub_notify()

    transport.fetch_viewer_login(provider)

    assert.is_false(runner_called)
    assert.is_nil(provider._viewer_login)
    assert.equals(1, #notify_calls)
    assert.is_not_nil(notify_calls[1].msg:find("'gh'", 1, true))
    assert.is_not_nil(notify_calls[1].msg:find("not found", 1, true))
    assert.equals(vim.log.levels.WARN, notify_calls[1].level)
  end)

  it("does not notify and calls runner when gh is available", function()
    transport._gh_available = true
    transport._executable = function(_bin)
      return 1
    end

    local runner_called = false
    local provider = make_provider({
      _runner = function(_cmd)
        runner_called = true
        return { code = 0, stdout = "testuser\n", stderr = "" }
      end,
    })
    provider._viewer_login = nil

    local notify_calls = stub_notify()

    transport.fetch_viewer_login(provider)

    assert.is_true(runner_called)
    assert.equals("testuser", provider._viewer_login)
    assert.equals(0, #notify_calls)
  end)

  it("skips runner and does not notify when _viewer_login is already cached", function()
    transport._gh_available = false
    transport._executable = function(_bin)
      return 0
    end

    local runner_called = false
    local provider = make_provider({
      _runner = function(_cmd)
        runner_called = true
        return { code = 0, stdout = "", stderr = "" }
      end,
    })
    provider._viewer_login = "cached-user"

    local notify_calls = stub_notify()

    transport.fetch_viewer_login(provider)

    assert.is_false(runner_called)
    assert.equals("cached-user", provider._viewer_login)
    assert.equals(0, #notify_calls)
  end)
end)
