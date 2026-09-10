local health = require("parley.health")
local vcs = require("parley.vcs")
local registry = require("parley.registry")

describe("delegated health diagnostics", function()
  local saved, reports, config, props
  before_each(function()
    saved = {}
    for k, v in pairs(health) do
      saved[k] = v
    end
    saved.detect = vcs.detect
    saved.registered = registry.registered
    reports = {}
    health._health = {}
    for _, level in ipairs({ "start", "ok", "info", "warn", "error" }) do
      health._health[level] = function(message)
        reports[#reports + 1] = { level = level, message = message }
      end
    end
    config = { cache_dir = "/tmp/parley-cache" }
    props = { name = "/checkout/f", buftype = "", filetype = "" }
    health._get_parley = function()
      return { config = config }
    end
    health._has_nvim_010 = function()
      return true
    end
    health._isdirectory = function()
      return 1
    end
    health._filewritable = function()
      return 1
    end
    health._get_buf_props = function()
      return props
    end
    health._require = function(name)
      if name == "plenary.async" then
        return require(name)
      end
      error("optional integration absent")
    end
    vcs.detect = function()
      return { vcs = "custom", root = "/checkout", branch = "branch" }
    end
    registry.registered = function()
      return {}
    end
  end)
  after_each(function()
    for k in pairs(health) do
      if saved[k] == nil then
        health[k] = nil
      end
    end
    for k, v in pairs(saved) do
      if k ~= "detect" and k ~= "registered" then
        health[k] = v
      end
    end
    vcs.detect, registry.registered = saved.detect, saved.registered
  end)

  --- @param level string
  --- @param text string
  local function expect(level, text)
    for _, report in ipairs(reports) do
      if report.level == level and report.message:find(text, 1, true) then
        return
      end
    end
    error("missing " .. level .. ": " .. text .. vim.inspect(reports))
  end

  --- @param hook function|nil
  local function provider(hook)
    registry.registered = function()
      return {
        {
          name = "Custom",
          detect = function()
            return { repository = "repo" }
          end,
          factory = function()
            error("health must not construct providers")
          end,
          health = hook,
        },
      }
    end
  end

  it("delegates context and renders diagnostics without constructing providers", function()
    provider(function(ctx)
      assert.equals("custom", ctx.vcs_info.vcs)
      assert.equals("repo", ctx.opts.repository)
      assert.equals(config, ctx.config)
      return { { level = "ok", message = "custom ready" } }
    end)
    health.check()
    expect("ok", "custom ready")
  end)

  it("preserves configuration and integration diagnostics", function()
    config.telescope = true
    health._filewritable = function()
      return 0
    end
    health.check()
    expect("warn", "cache_dir exists but is not writable")
    expect("warn", "telescope.nvim is enabled")
    health._has_nvim_010 = function()
      return false
    end
    health.check()
    expect("error", "Neovim >= 0.10 is required")
  end)

  it("handles an unavailable health-report source without detecting", function()
    props = { name = "health://", filetype = "checkhealth", buftype = "nofile" }
    health._alternate_buf = function()
      return -1
    end
    vcs.detect = function()
      error("must not detect")
    end
    health.check()
    expect("info", "source file buffer is unavailable")
  end)

  it("diagnoses a real Arc detection result without Git or API calls", function()
    local detector = require("parley.providers.arcanum.vcs_detector")
    local diagnostics = require("parley.providers.arcanum.diagnostics")
    local old_runner, old_executable, old_token = detector._runner, diagnostics._executable, diagnostics._read_token
    local commands = {}
    detector._runner = function(cmd)
      commands[#commands + 1] = cmd
      assert.equals("arc", cmd[1])
      return {
        code = 0,
        stdout = cmd[2] == "root" and "/checkout" or '{"remote":"users/alice/branch","user_login":"alice"}',
      }
    end
    diagnostics._executable = function(tool)
      assert.is_true(tool == "arc" or tool == "curl")
      return 1
    end
    diagnostics._read_token = function()
      return "SECRET"
    end
    vcs.detect = detector.detect
    registry.registered = function()
      return {
        {
          name = "Arcanum",
          detect = require("parley.providers.arcanum.provider").detect,
          factory = function()
            error("must not construct")
          end,
          health = diagnostics.check,
        },
      }
    end
    health.check()
    detector._runner, diagnostics._executable, diagnostics._read_token = old_runner, old_executable, old_token
    expect("ok", "Arcanum credential available locally")
    assert.equals(2, #commands)
    for _, report in ipairs(reports) do
      assert.is_nil(report.message:find("SECRET", 1, true))
    end
  end)

  it("handles missing hooks and unmatched repositories informationally", function()
    provider(nil)
    health.check()
    expect("info", "additional diagnostics unavailable")
    registry.registered = function()
      return {}
    end
    health.check()
    expect("info", "No registered provider")
  end)

  it("skips repository work before setup or without Plenary", function()
    vcs.detect = function()
      error("must not detect")
    end
    config = nil
    health.check()
    expect("warn", "setup() has not been called")
    config = {}
    health._require = function()
      error("missing")
    end
    health.check()
    expect("error", "plenary.async is not installed")
  end)

  it("skips unnamed and special buffers", function()
    vcs.detect = function()
      error("must not detect")
    end
    props = { name = "", buftype = "", filetype = "" }
    health.check()
    expect("info", "no file path")
    props = { name = "terminal", buftype = "terminal", filetype = "" }
    health.check()
    expect("info", "not a regular file")
  end)

  it("reports no repository without claiming missing tools", function()
    vcs.detect = function()
      return nil
    end
    health.check()
    expect("info", "No recognized repository")
    for _, report in ipairs(reports) do
      assert.is_false(report.level == "error")
    end
  end)

  it("contains failed hooks without leaking their exception text", function()
    provider(function()
      error("SECRET_TOKEN")
    end)
    health.check()
    expect("warn", "diagnostics failed")
    for _, report in ipairs(reports) do
      assert.is_nil(report.message:find("SECRET_TOKEN", 1, true))
    end
  end)

  it("rejects malformed hook results", function()
    provider(function()
      return { { level = "start", message = "invalid" } }
    end)
    health.check()
    expect("warn", "diagnostics failed")
  end)

  it("resolves the source file during a real checkhealth invocation", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, "/tmp/parley-health-origin")
    vim.api.nvim_set_current_buf(buf)
    health._get_buf_props = saved._get_buf_props
    health._health = nil
    local detected
    vcs.detect = function(path)
      detected = path
      return { vcs = "custom", root = "/checkout" }
    end
    provider(function()
      return { { level = "ok", message = "real health delegation" } }
    end)
    vim.cmd("checkhealth parley")
    local output = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    local report_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_delete(report_buf, { force = true })
    vim.api.nvim_buf_delete(buf, { force = true })
    assert.equals("/tmp/parley-health-origin", detected)
    assert.is_truthy(output:find("real health delegation", 1, true))
  end)

  it("ignores a late coroutine after timeout", function()
    local finish
    provider(function()
      require("parley.runtime.await").callback(function(cb)
        finish = cb
      end)
      return { { level = "ok", message = "late result" } }
    end)
    health._wait = function()
      return false
    end
    health.check()
    expect("warn", "timed out")
    local count = #reports
    finish()
    assert.equals(count, #reports)
  end)
end)
