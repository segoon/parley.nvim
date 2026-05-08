--- parley.nvim — inline PR discussion for Neovim
--- https://github.com/your-org/parley.nvim

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

  -- Ensure cache directory exists
  vim.fn.mkdir(M.config.cache_dir, "p")

  -- TODO: initialise provider registry
  -- TODO: register autocommands (BufEnter, timer)
  -- TODO: register keymaps
  -- TODO: register statusline component
end

return M
