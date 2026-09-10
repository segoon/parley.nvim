.PHONY: all lint format format-check test ci doc helptags check-doc

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
	@NEOVIM=$(NEOVIM) bash scripts/run_tests.sh

# ─── Documentation ────────────────────────────────────────────────────────────

doc:
	$(NEOVIM) --headless -l scripts/gendoc.lua

helptags:
	$(NEOVIM) --headless -c "helptags doc/" -c "qa!"

check-doc:
	$(NEOVIM) --headless -l scripts/gendoc.lua --check

# ─── Aggregate ────────────────────────────────────────────────────────────────

ci: lint format-check test check-doc

all: ci
