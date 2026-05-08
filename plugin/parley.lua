-- parley.nvim entry point
-- This file is sourced automatically by Neovim's plugin loader.

-- Load guard: prevent double-loading.
if vim.g.loaded_parley then
  return
end
vim.g.loaded_parley = true

-- Require Neovim 0.10+
if vim.fn.has("nvim-0.10") == 0 then
  vim.notify("parley.nvim requires Neovim >= 0.10", vim.log.levels.ERROR)
  return
end

-- Explicit setup() call is required; nothing is activated here automatically.
-- Users must call require("parley").setup({}) in their config.
