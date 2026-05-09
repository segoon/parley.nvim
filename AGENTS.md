## Core documentation

- @PROJECT.md - the core concept, the project goals, user scenarios
- @TODO.md - the plans
- @README.md - the main user documentation

## Quick Reference

**Language:** Lua. Neovim plugin. Minimum Neovim: 0.10.

**Layout:**
- `lua/parley/` — all plugin logic (modules go here)
- `plugin/parley.lua` — entry point, load guard only; no logic
- `tests/parley/` — mirrors `lua/parley/` structure

**Conventions**
- stylua
- luacheck
- luacats annotations (**MANDATORY**)
- make test + make format

**Requirements**
- `plenary.async`. No synchronous HTTP anywhere.

## Development

- Never call `git`, it is run manually by the user
- TDD
- DRY, KISS, SOLID
- UI quality is paramount
- When fixing a bug, search for similar bugs in the nearby code
- When found a bug, elaborate whether it is possible to redesign the system to make such bugs impossible
- max *.lua file size = 600 lines

## Documentation

- `doc/parley.nvim.txt` — the vim help file (`:help parley.nvim`)
- Configuration and Lua API sections are **generated** from LuaCATS annotations via `scripts/gendoc.lua`
- Run `make doc` after changing `@class`/`@field`/`@param`/`@return` annotations in `lua/parley/init.lua`
- Run `make check-doc` to verify the help file is up to date (also runs in CI)
- Any PR that adds or changes commands, keymaps, config options, or public API **must** update `doc/parley.nvim.txt`

## User interaction

User experience is the priority.
Handle anything related to user interaction very carefully.
Examples:
- UI elements (windows, labels, keymaps)
- error messages
- documentation
- setup()
- user commands
