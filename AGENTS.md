## Core documentation

- @PROJECT.md - the core concept, the project goals, user scenarios
- @TODO.md - the plans
- @README.md - the main user documentation
- @GITHUB_COMPATIBILITY.md - current GitHub contracts and validation limits
- @ARCANUM_COMPATIBILITY.md - current Arcanum contracts and validation limits

## Quick Reference

**Language:** Lua. Neovim plugin. Minimum Neovim: 0.10.

**Layout:**
- `lua/parley/` — all plugin logic (modules go here)
- `lua/parley/providers/` - provider-specific code/data lives only here
- `plugin/parley.lua` — entry point, load guard only; no logic
- `tests/parley/` — mirrors `lua/parley/` structure

**Conventions**
- stylua
- luacheck
- luacats annotations (**MANDATORY**)
- make test + make format + make lint
- architecture layers in `policy.json`

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
- core modules must not depend on providers; use DI to reverse the dependency direction if required

## Documentation

- `doc/parley.nvim.txt.in` — the vim help file template (`:help parley.nvim`)
- do not edit `doc/parley.nvim.txt`
- Any PR that adds or changes commands, keymaps, config options, or public API **must** update the template file

## User interaction

User experience is the priority.
Handle anything related to user interaction very carefully.
Examples:
- UI elements (windows, labels, keymaps)
- error messages
- documentation
- setup()
- user commands
