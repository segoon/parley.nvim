#!/usr/bin/env bash
set -o pipefail

"${NEOVIM:-nvim}" --headless \
  -u tests/minimal_init.lua \
  -c "lua require('plenary.test_harness').test_directory('tests/', { minimal_init = 'tests/minimal_init.lua', sequential = true })" \
  2>&1 | grep -v $'^\x1b\[32mSuccess\x1b\[0m'
