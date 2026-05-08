--- parley.nvim — inline PR discussion for Neovim
--- https://github.com/your-org/parley.nvim

local cache = require("parley.cache")
local nav = require("parley.nav")
local read_service = require("parley.services.read")
local registry = require("parley.registry")
local signs = require("parley.signs")

local M = {}

--- Default configuration values.
--- @class parley.Config
--- @field refresh_interval integer  Auto-refresh interval in seconds (0 = disabled)
--- @field cache_dir         string  Directory for disk-cached API responses
--- @field signs             parley.SignsConfig
--- @field virtual_text      parley.VirtualTextConfig
--- @field float             parley.FloatConfig
--- @field progress          parley.ProgressConfig
--- @field keymaps           parley.KeymapsConfig
--- @field providers         table<string, table>  Provider-specific options

--- @class parley.SignsConfig
--- @field enabled  boolean
--- @field text     string  Gutter sign character

--- @class parley.VirtualTextConfig
--- @field enabled   boolean
--- @field max_width integer  Maximum characters shown in virtual text snippet

--- @class parley.FloatConfig
--- @field border    string   Border style (see `:h nvim_open_win`)
--- @field max_width integer
--- @field max_height integer

--- @class parley.ProgressConfig
--- @field enabled           boolean
--- @field border            string
--- @field max_width         integer
--- @field max_height        integer
--- @field success_timeout   integer
--- @field failed_timeout    integer
--- @field cancelled_timeout integer
--- @field margin_bottom     integer
--- @field margin_right      integer
--- @field spinner_interval  integer

--- @class parley.KeymapsConfig
--- @field next_comment string  Jump to next commented line
--- @field prev_comment string  Jump to previous commented line

--- @type parley.Config
local defaults = {
  refresh_interval = 300, -- 5 minutes
  cache_dir = vim.fn.stdpath("cache") .. "/parley",
  signs = {
    enabled = true,
    text = "▐",
  },
  virtual_text = {
    enabled = true,
    max_width = 60,
  },
  float = {
    border = "rounded",
    max_width = 80,
    max_height = 30,
  },
  progress = {
    enabled = true,
    border = "rounded",
    max_width = 60,
    max_height = 8,
    success_timeout = 1200,
    failed_timeout = 2500,
    cancelled_timeout = 1200,
    margin_bottom = 1,
    margin_right = 2,
    spinner_interval = 100,
  },
  keymaps = {
    next_comment = "]c",
    prev_comment = "[c",
  },
  providers = {},
}

--- Active (merged) configuration. Nil until setup() is called.
--- @type parley.Config | nil
M.config = nil

--- @type table<string, string[]>
local PARLEY_GROUPS = {
  discussion = { "open", "close", "toggle", "new", "reply" },
  nav = { "next", "prev" },
}

local PARLEY_GROUP_NAMES = { "discussion", "nav" }

--- @param items string[]
--- @param prefix string
--- @return string[]
local function filter_prefix(items, prefix)
  local out = {}
  for _, item in ipairs(items) do
    if prefix == "" or vim.startswith(item, prefix) then
      out[#out + 1] = item
    end
  end
  return out
end

--- Completion callback for `:Parley`.
--- @param arg_lead string
--- @param cmd_line string
--- @return string[]
function M._complete_parley(arg_lead, cmd_line)
  local args = {}
  for token in cmd_line:gmatch("%S+") do
    args[#args + 1] = token
  end
  if args[1] and args[1]:match("^:?Parley$") then
    table.remove(args, 1)
  end

  local trailing_space = cmd_line:match("%s$") ~= nil
  if #args == 0 then
    return filter_prefix(PARLEY_GROUP_NAMES, arg_lead)
  end
  if #args == 1 then
    if trailing_space then
      return PARLEY_GROUPS[args[1]] or {}
    end
    return filter_prefix(PARLEY_GROUP_NAMES, arg_lead)
  end
  if #args == 2 and not trailing_space then
    return filter_prefix(PARLEY_GROUPS[args[1]] or {}, arg_lead)
  end
  return {}
end

--- Dispatch parsed `:Parley` arguments for `bufnr`.
--- @param fargs string[]
--- @param bufnr integer
--- @param cmd_opts? table
function M._dispatch_parley(fargs, bufnr, cmd_opts)
  cmd_opts = cmd_opts or {}
  local group = fargs[1]
  local action = fargs[2]

  if group == nil or group == "" then
    error("parley: expected a command group", 0)
  end

  if group == "discussion" then
    local discussion_window = require("parley.discussion_window")
    if action == nil or action == "" then
      error("parley: expected a discussion action", 0)
    end
    if action == "open" then
      discussion_window.open_current_line(bufnr)
      return
    end
    if action == "close" then
      discussion_window.close(bufnr)
      return
    end
    if action == "toggle" then
      discussion_window.toggle_current_line(bufnr)
      return
    end
    if action == "new" then
      require("parley.services.write").open_new_comment_input(discussion_window.resolve_source_bufnr(bufnr), {
        range = cmd_opts.range,
        line1 = cmd_opts.line1,
        line2 = cmd_opts.line2,
      })
      return
    end
    if action == "reply" then
      discussion_window.reply_current_line(bufnr)
      return
    end
    error("parley: unknown discussion action: " .. tostring(action), 0)
  end

  if group == "nav" then
    local nav_mod = require("parley.nav")
    if action == nil or action == "" then
      error("parley: expected a nav action", 0)
    end
    if action == "next" then
      nav_mod.next(bufnr)
      return
    end
    if action == "prev" then
      nav_mod.prev(bufnr)
      return
    end
    error("parley: unknown nav action: " .. tostring(action), 0)
  end

  error("parley: unknown command group: " .. tostring(group), 0)
end

--- Set up parley.nvim.
---
--- Call this once from your Neovim config:
---
--- ```lua
--- require("parley").setup({
---   refresh_interval = 120,
--- })
--- ```
---
--- @param opts parley.Config | nil  Partial config; merged with defaults.
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", defaults, opts or {})

  -- Ensure cache directory exists and initialise the cache module.
  vim.fn.mkdir(M.config.cache_dir, "p")
  cache.setup({ cache_dir = M.config.cache_dir })

  -- Define highlight groups for signs and virtual text.
  signs.setup_highlights()
  require("parley.progress_popup").setup()

  -- Reset and re-populate the provider registry on every setup() call so
  -- that calling setup() twice produces a clean, deterministic state.
  -- Built-in provider specs are registered here as they are implemented
  -- (Step 9+).  User-supplied providers can call registry.register() after
  -- setup() if needed.
  registry.reset()

  -- Register built-in providers.
  local gh = require("parley.providers.github.provider")
  registry.register({
    name = "GitHub",
    detect = gh.detect,
    factory = gh.new,
  })
  -- Register navigation keymaps (global; act on the current buffer at call time).
  -- An empty string disables the keymap.
  if M.config.keymaps.next_comment ~= "" then
    vim.keymap.set("n", M.config.keymaps.next_comment, function()
      nav.next(vim.api.nvim_get_current_buf())
    end, { desc = "Jump to next Parley comment" })
  end
  if M.config.keymaps.prev_comment ~= "" then
    vim.keymap.set("n", M.config.keymaps.prev_comment, function()
      nav.prev(vim.api.nvim_get_current_buf())
    end, { desc = "Jump to previous Parley comment" })
  end

  -- BufEnter triggers a refresh; the read service's classify step decides
  -- whether the buffer actually warrants a fetch (regular file in a VCS repo
  -- whose remote matches a registered provider).
  local augroup = vim.api.nvim_create_augroup("parley", { clear = true })
  pcall(vim.api.nvim_del_user_command, "Parley")
  pcall(vim.api.nvim_del_user_command, "ParleyRefresh")

  vim.api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    callback = function(args)
      read_service.refresh_async(args.buf, { notify_errors = false })
    end,
    desc = "Parley: refresh PR discussions on buffer enter",
  })

  vim.api.nvim_create_user_command("Parley", function(cmd_opts)
    M._dispatch_parley(cmd_opts.fargs, vim.api.nvim_get_current_buf(), cmd_opts)
  end, {
    nargs = "*",
    range = true,
    complete = function(arg_lead, cmd_line, _cursor_pos)
      return M._complete_parley(arg_lead, cmd_line)
    end,
    desc = "Parley commands",
  })

  vim.api.nvim_create_user_command("ParleyRefresh", function()
    read_service.refresh_async(vim.api.nvim_get_current_buf(), { force = true })
  end, { desc = "Re-fetch PR discussions for the current buffer" })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = augroup,
    callback = function(args)
      local discussion_window = require("parley.discussion_window")
      discussion_window.close(args.buf)
      read_service.clear_buffer_state(args.buf)
    end,
    desc = "Parley: clean up discussion state on buffer wipeout",
  })
end

return M
