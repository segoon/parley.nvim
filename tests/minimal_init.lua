-- Minimal Neovim init for the plenary.nvim test runner.
-- Used by: `make test` and CI.
--
-- This file is passed via `nvim -u tests/minimal_init.lua`.
-- It does NOT load the user's actual init.lua.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")

-- Add the plugin itself to runtimepath
vim.opt.rtp:prepend(root)

-- Add plenary.nvim (cloned into .tests/ by `make deps` / CI)
local plenary_path = root .. "/.tests/plenary.nvim"
vim.opt.rtp:prepend(plenary_path)

-- Source plenary's plugin file so its runtime modules are available
vim.cmd("runtime plugin/plenary.vim")

-- Disable unnecessary providers to speed up startup
vim.g.loaded_node_provider = 0
vim.g.loaded_python3_provider = 0
vim.g.loaded_perl_provider = 0
vim.g.loaded_ruby_provider = 0
