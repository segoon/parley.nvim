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

--- @type fun(bin: string): boolean|integer
M._executable = function(bin)
  return vim.fn.executable(bin)
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

--- @type fun(cmd: string[], cwd: string): { code: integer, stdout: string, stderr: string }
M._run = function(cmd, cwd)
  local result = vim.system(cmd, { cwd = cwd, text = true }):wait()
  return {
    code = result.code or 0,
    stdout = result.stdout or "",
    stderr = result.stderr or "",
  }
end

--- @type fun(host: string): string|nil, string|nil
M._read_github_token = function(host)
  return require("parley.providers.github.auth").read_token(host)
end

--- @type fun(url: string|nil): { host: string, owner: string, repo: string }|nil
M._parse_remote_url = function(url)
  return require("parley.providers.github.provider")._parse_remote_url(url)
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

--- @param text string
--- @return string
local function trim(text)
  return (text or ""):gsub("%s+$", "")
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

  if try_require("plenary.async") then
    health.ok("plenary.async is installed")
  else
    health.error("plenary.async is not installed")
  end

  if is_true(M._executable("git")) then
    health.ok("git executable found")
  else
    health.error("git executable not found")
  end

  if is_true(M._executable("gh")) then
    health.ok("gh executable found")
  else
    health.error("gh executable not found")
  end
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

--- @param repo_root string
--- @return string|nil
local function detect_branch(repo_root)
  local result = M._run({ "git", "rev-parse", "--abbrev-ref", "HEAD" }, repo_root)
  if result.code ~= 0 then
    return nil
  end

  local branch = trim(result.stdout)
  if branch == "" or branch == "HEAD" then
    return nil
  end
  return branch
end

--- @param repo_root string
--- @return string|nil
local function detect_remote(repo_root)
  local result = M._run({ "git", "remote", "get-url", "origin" }, repo_root)
  if result.code ~= 0 then
    return nil
  end
  local remote_url = trim(result.stdout)
  if remote_url == "" then
    return nil
  end
  return remote_url
end

local function check_current_buffer()
  local health = health_api()
  health.start("Current Buffer")

  local bufnr = M._current_buf()
  local props = M._get_buf_props(bufnr)
  if props.buftype ~= "" then
    health.info("current buffer buftype=" .. props.buftype .. " is not a regular file buffer")
    return
  end

  if props.name == "" then
    health.info("current buffer has no file path")
    return
  end

  if not is_true(M._executable("git")) then
    health.warn("cannot inspect current buffer repository because git is unavailable")
    return
  end

  local cwd = parent_dir(props.name)
  local root_result = M._run({ "git", "rev-parse", "--show-toplevel" }, cwd)
  if root_result.code ~= 0 then
    health.info("current buffer is not in a git repository")
    return
  end

  local repo_root = trim(root_result.stdout)
  health.ok("current buffer is in git repository: " .. repo_root)

  local branch = detect_branch(repo_root)
  if branch then
    health.ok("current branch: " .. branch)
  else
    health.info("current branch could not be determined (possibly detached HEAD)")
  end

  local remote_url = detect_remote(repo_root)
  if not remote_url then
    health.warn("origin remote is not configured")
    return
  end
  health.ok("origin remote: " .. remote_url)

  local parsed = M._parse_remote_url(remote_url)
  if not parsed then
    health.warn("origin remote format is not recognized by Parley: " .. remote_url)
    return
  end

  if parsed.host ~= "github.com" then
    health.warn("current repository host " .. parsed.host .. " is not supported yet")
    return
  end

  health.ok("GitHub provider matches current repository")

  local token, err = M._read_github_token(parsed.host)
  if token then
    health.ok("GitHub authentication token resolved for " .. parsed.host)
  else
    health.warn("GitHub auth is not configured for " .. parsed.host .. ": " .. tostring(err or "unknown error"))
  end

  health.info("PR detection is not probed during checkhealth because it would require a live API call")
end

function M.check()
  check_runtime()
  local _, config = check_configuration()
  check_integrations(config)
  check_current_buffer()
end

return M
