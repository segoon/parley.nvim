--- parley.health — :checkhealth support for parley.nvim.

local M = {}

--- @type table|nil
M._health = nil

--- @type fun(name: string): any
M._require = require

--- @type fun(): boolean
M._has_nvim_010 = function()
  return vim.fn.has("nvim-0.10") == 1
end

--- @type fun(): table|nil
M._get_parley = function()
  return require("parley")
end

--- @type fun(path: string): boolean|integer
M._isdirectory = function(path)
  return vim.fn.isdirectory(path)
end

--- @type fun(path: string): boolean|integer
M._filewritable = function(path)
  return vim.fn.filewritable(path)
end

--- @type fun(): integer
M._current_buf = function()
  return vim.api.nvim_get_current_buf()
end

--- @type fun(bufnr: integer): { name: string, buftype: string, filetype: string }
M._get_buf_props = function(bufnr)
  return {
    name = vim.api.nvim_buf_get_name(bufnr),
    buftype = vim.bo[bufnr].buftype,
    filetype = vim.bo[bufnr].filetype,
  }
end

--- @type fun(timeout: integer, predicate: fun(): boolean): boolean
M._wait = function(timeout, predicate)
  return vim.wait(timeout, predicate, 20)
end

--- @type fun(): integer
M._alternate_buf = function()
  return vim.fn.bufnr("#")
end

--- @return table
local function health_api()
  return M._health or vim.health
end

--- @param value boolean|integer
--- @return boolean
local function is_true(value)
  return value == true or value == 1 or value == 2
end

--- @param path string
--- @return string
local function parent_dir(path)
  return vim.fn.fnamemodify(path, ":p:h")
end

--- @param path string
--- @return boolean
local function dir_exists(path)
  return type(path) == "string" and path ~= "" and is_true(M._isdirectory(path))
end

--- @param path string
--- @return boolean
local function path_writable(path)
  return type(path) == "string" and path ~= "" and is_true(M._filewritable(path))
end

--- @param name string
--- @return boolean, any
local function try_require(name)
  return pcall(M._require, name)
end

local function check_runtime()
  local health = health_api()
  health.start("Runtime")

  if M._has_nvim_010() then
    health.ok("Neovim >= 0.10 detected")
  else
    health.error("Neovim >= 0.10 is required")
  end

  local available, async = try_require("plenary.async")
  if available then
    health.ok("plenary.async is installed")
  else
    health.error("plenary.async is not installed")
  end

  return available, async
end

--- @return table|nil, table|nil
local function check_configuration()
  local health = health_api()
  health.start("Configuration")

  local ok, parley = pcall(M._get_parley)
  if not ok or type(parley) ~= "table" then
    health.error("failed to require parley")
    return nil, nil
  end

  local config = parley.config
  if config then
    health.ok("parley.setup() has been called")
  else
    health.warn("parley.setup() has not been called")
    return parley, nil
  end

  local cache_dir = config.cache_dir
  if type(cache_dir) ~= "string" or cache_dir == "" then
    health.warn("cache_dir is not configured")
    return parley, config
  end

  if dir_exists(cache_dir) then
    if path_writable(cache_dir) then
      health.ok("cache_dir exists and is writable: " .. cache_dir)
    else
      health.warn("cache_dir exists but is not writable: " .. cache_dir)
    end
    return parley, config
  end

  local parent = parent_dir(cache_dir)
  if dir_exists(parent) and path_writable(parent) then
    health.info("cache_dir does not exist yet, but setup() can create it: " .. cache_dir)
  else
    health.warn("cache_dir does not exist and its parent is not writable: " .. cache_dir)
  end

  return parley, config
end

--- @param config table|nil
local function check_integrations(config)
  local health = health_api()
  health.start("Integrations")

  local telescope_enabled = config and config.telescope == true
  if try_require("telescope") then
    health.ok("telescope.nvim is installed")
  elseif telescope_enabled then
    health.warn("telescope.nvim is enabled in Parley config but not installed")
  else
    health.info("telescope.nvim is not installed")
  end

  if try_require("render-markdown") then
    health.ok("render-markdown.nvim is installed")
  else
    health.info("render-markdown.nvim is not installed")
  end
end

--- Resolve the originating file when :checkhealth has switched to its report.
--- @return table|nil
local function source_props()
  local props = M._get_buf_props(M._current_buf())
  if props.name == "health://" or props.filetype == "checkhealth" then
    local alternate = M._alternate_buf()
    if alternate < 1 or not vim.api.nvim_buf_is_valid(alternate) then
      return nil
    end
    props = M._get_buf_props(alternate)
    if props.buftype ~= "" or props.name == "" then
      return nil
    end
  end
  return props
end

--- Gather provider diagnostics without constructing a provider or publishing UI.
--- @param path string
--- @param config table
--- @return parley.HealthEntry[]
local function collect(path, config)
  local info = require("parley.vcs").detect(path)
  if not info then
    return { { level = "info", message = "No recognized repository for the source file" } }
  end
  local entries = { { level = "ok", message = "Repository: " .. info.root } }
  for _, spec in ipairs(require("parley.registry").registered()) do
    local opts = spec.detect(info)
    if opts ~= nil then
      entries[#entries + 1] = { level = "ok", message = spec.name .. " provider matches current repository" }
      if spec.health then
        local result = spec.health({ vcs_info = info, opts = opts, config = config })
        assert(type(result) == "table", "invalid health results")
        for _, entry in ipairs(result) do
          assert(type(entry) == "table" and type(entry.message) == "string", "invalid health entry")
          assert(vim.tbl_contains({ "ok", "info", "warn", "error" }, entry.level), "invalid health level")
          entries[#entries + 1] = entry
        end
      else
        entries[#entries + 1] = { level = "info", message = spec.name .. ": additional diagnostics unavailable" }
      end
      return entries
    end
  end
  entries[#entries + 1] = { level = "info", message = "No registered provider matches the current repository" }
  return entries
end

--- @param props table|nil
--- @param config table|nil
--- @param async table|nil
local function check_repository(props, config, async)
  local health = health_api()
  health.start("Current Repository")
  if not config or not async then
    health.info("Repository diagnostics skipped: setup and plenary.async are required")
    return
  end
  if not props then
    health.info("Repository diagnostics skipped: source file buffer is unavailable")
    return
  end
  if props.buftype ~= "" then
    health.info("Source buffer is not a regular file")
    return
  end
  if props.name == "" then
    health.info("Source buffer has no file path")
    return
  end
  local done, active, entries = false, true, nil
  async.run(function()
    local ok, result = pcall(collect, props.name, config)
    if not active then
      return
    end
    entries = ok and result or { { level = "warn", message = "Repository diagnostics failed" } }
    done = true
  end)
  if not done then
    M._wait(10000, function()
      return done
    end)
  end
  active = false
  if not done then
    health.warn("Repository diagnostics timed out after 10 seconds")
    return
  end
  for _, entry in ipairs(entries) do
    health[entry.level](entry.message)
  end
  health.info("Credentials are checked locally; authentication and PR detection are not verified with the server")
end

function M.check()
  local props = source_props()
  local available, async = check_runtime()
  local _, config = check_configuration()
  check_integrations(config)
  check_repository(props, config, available and async or nil)
end

return M
