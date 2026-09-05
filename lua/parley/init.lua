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
--- @field refresh_interval integer  Seconds between visible-review polling rounds; 0 disables periodic refresh
--- @field cache_dir         string  Directory for disk-cached API responses
--- @field signs             parley.SignsConfig
--- @field virtual_text      parley.VirtualTextConfig
--- @field float             parley.FloatConfig
--- @field progress          parley.ProgressConfig
--- @field telescope         boolean  Auto-register Parley Telescope extensions during setup
--- @field keymaps           parley.KeymapsConfig
--- @field providers         table<string, table>  Provider-specific options
--- @field debug             boolean  Write trace logs to stdpath("log")/parley.log

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
--- @field buf_next    string  Jump to next commented line in buffer
--- @field buf_prev    string  Jump to previous commented line in buffer
--- @field review_next string  Jump to next comment in the whole review
--- @field review_prev string  Jump to previous comment in the whole review

--- @type parley.Config
local defaults = {
  refresh_interval = 300, -- Seconds between background refresh rounds
  cache_dir = vim.fn.stdpath("cache") .. "/parley",
  debug = false,
  telescope = true,
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
    buf_next = "]c",
    buf_prev = "[c",
    review_next = "]C",
    review_prev = "[C",
  },
  providers = {},
}

--- Active (merged) configuration. Nil until setup() is called.
--- @type parley.Config | nil
M.config = nil

M._notify = function(msg, level)
  vim.notify(msg, level)
end

local commands = require("parley.commands")
local PARLEY_GROUPS, PARLEY_TOP_LEVEL = commands.groups, commands.top_level

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
    return filter_prefix(PARLEY_TOP_LEVEL, arg_lead)
  end
  if #args == 1 then
    if trailing_space then
      return PARLEY_GROUPS[args[1]] or {}
    end
    return filter_prefix(PARLEY_TOP_LEVEL, arg_lead)
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
    error("parley: expected a command", 0)
  end

  if group == "refresh" then
    read_service.refresh_async(bufnr, { force = true, progress = true })
    return
  end

  if group == "review" then
    if action ~= "actions" then
      error("parley: expected review actions", 0)
    end
    require("parley.review_actions").run(bufnr)
    return
  end

  if group == "quickfix" then
    if action ~= nil and action ~= "" then
      error("parley: quickfix does not accept subcommands", 0)
    end
    require("parley.quickfix").open(bufnr)
    return
  end

  if group == "discussion" then
    local discussion_window = require("parley.discussion_window")
    if action == nil or action == "" then
      error("parley: expected a discussion action", 0)
    end
    if commands.issue_actions[action] then
      require("parley.discussion_actions").run(bufnr, commands.issue_actions[action])
      return
    end
    if action == "list" then
      require("parley.discussion_picker").open(bufnr)
      return
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
    if action == "buf-next" then
      nav_mod.buf_next(bufnr)
      return
    end
    if action == "buf-prev" then
      nav_mod.buf_prev(bufnr)
      return
    end
    if action == "review-next" then
      nav_mod.review_next(bufnr)
      return
    end
    if action == "review-prev" then
      nav_mod.review_prev(bufnr)
      return
    end
    error("parley: unknown nav action: " .. tostring(action), 0)
  end

  if group == "comment" then
    local discussion_window = require("parley.discussion_window")
    if action == nil or action == "" then
      error("parley: expected a comment action", 0)
    end
    if action == "react" then
      discussion_window.react_current_comment(bufnr)
      return
    end
    if action == "edit" then
      discussion_window.edit_current_comment(bufnr)
      return
    end
    if action == "delete" then
      discussion_window.delete_current_comment(bufnr)
      return
    end
    error("parley: unknown comment action: " .. tostring(action), 0)
  end

  error("parley: unknown command group: " .. tostring(group), 0)
end

--- Return a statusline component string for `bufnr`.
--- Suitable for lualine function components and `%!v:lua.require("parley").statusline()`.
--- @param bufnr? integer
--- @return string
function M.statusline(bufnr)
  return require("parley.statusline").component(bufnr)
end

--- Set up parley.nvim.
---
--- Call this once from your Neovim config:
---
--- ```lua
--- require("parley").setup({
---   telescope = false,
--- })
--- ```
---
--- @param opts parley.Config | nil  Partial config; merged with defaults.
function M.setup(opts)
  local providers = require("parley.providers")
  local config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), { providers = providers.defaults() }, opts or {})
  local periodic = require("parley.periodic_refresh")
  periodic.validate(config.refresh_interval)
  M.config = config

  require("parley.debug").tracing_enable(M.config.debug)

  -- cache.setup() owns cache-dir creation.
  cache.setup({ cache_dir = M.config.cache_dir })

  -- Define highlight groups for signs and virtual text.
  signs.setup_highlights()
  require("parley.progress_popup").setup()

  -- Reset and re-populate the provider registry and VCS detectors on every
  -- setup() call so that calling setup() twice produces a clean state.
  -- User-supplied providers can call registry.register() after setup() if needed.
  registry.reset()
  local vcs = require("parley.vcs")
  vcs.reset_detectors()

  vcs.reset_adapters()
  providers.register({ registry = registry, vcs = vcs }, M.config.providers)

  if M.config.telescope then
    local ok_telescope, telescope = pcall(require, "telescope")
    if ok_telescope then
      telescope.load_extension("parley_discussions")
      telescope.load_extension("parley_discussions_file")
    else
      M._notify("parley: telescope.nvim is not installed", vim.log.levels.WARN)
    end
  end

  -- Register navigation keymaps (global; act on the current buffer at call time).
  -- An empty string disables the keymap.
  if M.config.keymaps.buf_next ~= "" then
    vim.keymap.set("n", M.config.keymaps.buf_next, function()
      nav.buf_next(vim.api.nvim_get_current_buf())
    end, { desc = "Jump to next Parley comment in buffer" })
  end
  if M.config.keymaps.buf_prev ~= "" then
    vim.keymap.set("n", M.config.keymaps.buf_prev, function()
      nav.buf_prev(vim.api.nvim_get_current_buf())
    end, { desc = "Jump to previous Parley comment in buffer" })
  end
  if M.config.keymaps.review_next ~= "" then
    vim.keymap.set("n", M.config.keymaps.review_next, function()
      nav.review_next(vim.api.nvim_get_current_buf())
    end, { desc = "Jump to next Parley comment in review" })
  end
  if M.config.keymaps.review_prev ~= "" then
    vim.keymap.set("n", M.config.keymaps.review_prev, function()
      nav.review_prev(vim.api.nvim_get_current_buf())
    end, { desc = "Jump to previous Parley comment in review" })
  end

  -- BufEnter triggers a refresh; the read service's classify step decides
  -- whether the buffer actually warrants a fetch (regular file in a VCS repo
  -- whose remote matches a registered provider).
  local augroup = vim.api.nvim_create_augroup("parley", { clear = true })
  pcall(vim.api.nvim_del_user_command, "Parley")
  periodic.setup(M.config.refresh_interval)
  vim.api.nvim_create_autocmd({ "FocusLost", "FocusGained" }, {
    group = augroup,
    callback = function(args)
      periodic.focus(args.event == "FocusGained")
    end,
    desc = "Parley: pause periodic refresh while unfocused",
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = augroup,
    callback = periodic.stop,
    desc = "Parley: stop periodic refresh",
  })

  vim.api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    callback = function(args)
      read_service.refresh_async(args.buf, { notify_errors = false })
    end,
    desc = "Parley: refresh PR discussions on buffer enter",
  })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWritePost", "BufReadPost", "BufUnload" }, {
    group = augroup,
    callback = function(args)
      require("parley.repositories.review").remap_async(args.buf)
    end,
    desc = "Parley: update local discussion positions",
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
