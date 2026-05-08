## Core documentation

- @PROJECT.md - the core concept, the project goals, user scenarios
- @TODO.md - the plans
- @POSTPONED.md - postponed features

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
