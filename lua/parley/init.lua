--- parley.nvim — inline PR discussion for Neovim
--- https://github.com/your-org/parley.nvim

local cache = require("parley.cache")
local nav = require("parley.nav")
local orchestrator = require("parley.orchestrator")
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
  keymaps = {
    next_comment = "]c",
    prev_comment = "[c",
  },
  providers = {},
}

--- Active (merged) configuration. Nil until setup() is called.
--- @type parley.Config | nil
M.config = nil

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

  -- BufEnter triggers a refresh; the orchestrator's classify step decides
  -- whether the buffer actually warrants a fetch (regular file in a VCS repo
  -- whose remote matches a registered provider).
  local augroup = vim.api.nvim_create_augroup("parley", { clear = true })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    callback = function(args)
      orchestrator.refresh_async(args.buf)
    end,
    desc = "Parley: refresh PR discussions on buffer enter",
  })

  -- :ParleyRefresh — manual re-fetch that bypasses the stale-cache shortcut.
  vim.api.nvim_create_user_command("ParleyRefresh", function()
    orchestrator.refresh_async(vim.api.nvim_get_current_buf(), { force = true })
  end, { desc = "Re-fetch PR discussions for the current buffer" })

  -- TODO: register statusline component
end

return M
