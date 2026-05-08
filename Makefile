.PHONY: all lint format format-check test ci

# Directories
LUA_DIRS := lua/ plugin/ tests/

# ─── Linting ──────────────────────────────────────────────────────────────────

lint:
	luacheck -q $(LUA_DIRS)

# ─── Formatting ───────────────────────────────────────────────────────────────

format:
	stylua $(LUA_DIRS)

format-check:
	stylua --check $(LUA_DIRS)

# ─── Testing ──────────────────────────────────────────────────────────────────
#
# Runs the plenary.nvim busted test harness in a headless Neovim instance.
# Requires plenary.nvim to be cloned into .tests/plenary.nvim (done by CI or
# by running `make deps` locally).

PLENARY_PATH := .tests/plenary.nvim
NEOVIM       ?= nvim

deps:
	@mkdir -p .tests
	@if [ ! -d "$(PLENARY_PATH)" ]; then \
		git clone --depth=1 https://github.com/nvim-lua/plenary.nvim $(PLENARY_PATH); \
	else \
		echo "plenary.nvim already present"; \
	fi

test:
	@output=$$($(NEOVIM) --headless \
		-u tests/minimal_init.lua \
		-c "lua require('plenary.test_harness').test_directory('tests/', { minimal_init = 'tests/minimal_init.lua', sequential = true })" \
		2>&1); \
	exit_code=$$?; \
	if [ $$exit_code -eq 0 ]; then echo "OK"; else printf '%s\n' "$$output"; fi; \
	exit $$exit_code

# ─── Aggregate ────────────────────────────────────────────────────────────────

ci: lint format-check test

all: ci
