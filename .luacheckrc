-- luacheck configuration for parley.nvim
-- https://luacheck.readthedocs.io/en/stable/config.html

std = "luajit"

-- Maximum line length (matches stylua.toml column_width)
max_line_length = 120

-- Neovim global
globals = {
  "vim",
}

-- Busted test globals (read-only: we don't redefine them)
read_globals = {
  "describe",
  "it",
  "before_each",
  "after_each",
  "pending",
  "assert",
  "spy",
  "stub",
  "mock",
}

-- Ignore warnings about unused arguments prefixed with _
unused_args = true
ignore = {
  "212/_.*", -- unused argument (prefixed with _)
  "411",     -- redefining a local variable (common in module patterns)
}

-- Per-file overrides
files["tests/**/*.lua"] = {
  -- Tests may use all busted globals as writable
  globals = {
    "describe",
    "it",
    "before_each",
    "after_each",
    "pending",
    "assert",
    "spy",
    "stub",
    "mock",
  },
}
