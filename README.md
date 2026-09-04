# parley.nvim

Inline pull request discussions for Neovim.

`parley.nvim` lets you read and act on PR review threads directly from the buffer: inline signs, virtual text, a floating discussion view, replies, edits, reactions, and navigation without leaving Neovim.

> [!WARNING]
> Early-stage plugin.
> Current support is GitHub only, regular file buffers only, and some planned features are not exposed yet.

## Features

- Detect the active PR for the current branch on GitHub / Yandex Arcanum
- Render commented lines with signs and virtual text
- Open a floating discussion window for the current line
- Add new top-level comments on a line or range
- Reply to, edit, delete, and react to comments
- Navigate commented lines within a buffer (`]c` / `[c`) or across the whole review (`]C` / `[C`)
- Fill the quickfix list with all discussion locations in the active review
- Expose a statusline component with PR number, review state, and unresolved count
- Cache PR and discussion data on disk
- Refresh asynchronously on `BufEnter` and on demand
- Provide optional Telescope pickers for all discussions or current-file discussions
- Include `:checkhealth parley`

## Scope

Parley is focused on line-level code review inside the editor.

Plugins like [`octo.nvim`](https://github.com/pwntester/octo.nvim) and [`gh.nvim`](https://github.com/ldelossa/gh.nvim) go much deeper into the GitHub feature surface: issues, PR metadata, review management, notifications, repo browsing, and general GitHub workflows.

Parley is intentionally narrower. The goal is to make reading and responding to review comments feel native in normal editing workflows, instead of building a full GitHub client inside Neovim.

## Requirements

- Neovim `>= 0.10`
- `git`
- `gh`
- [`nvim-lua/plenary.nvim`](https://github.com/nvim-lua/plenary.nvim)

Optional:

- [`nvim-telescope/telescope.nvim`](https://github.com/nvim-telescope/telescope.nvim)
- [`MeanderingProgrammer/render-markdown.nvim`](https://github.com/MeanderingProgrammer/render-markdown.nvim)

## Installation

### lazy.nvim

```lua
{
  "segoon/parley.nvim",
  dependencies = {
    "nvim-lua/plenary.nvim",
    -- Optional:
    -- "nvim-telescope/telescope.nvim",
    -- "MeanderingProgrammer/render-markdown.nvim",
  },
  opts = {},
}
```

### Minimal setup

```lua
require("parley").setup({})
```

If you do not use Telescope, disable auto-loading its extensions:

```lua
require("parley").setup({
  telescope = false,
})
```

## Quick Start

1. Install the plugin and call `require("parley").setup({})`.
2. (for GitHub) Authenticate GitHub CLI with `gh auth login`.
3. Open a file inside a repository whose current branch has an open PR.
4. Use `]c` / `[c` to move between commented lines in the buffer, or `]C` / `[C` to jump across all files in the review.
5. Use `:Parley discussion toggle` to open the discussion window for the current line.
6. Use `:Parley quickfix` to open all discussion locations in quickfix.

If no matching PR is found, Parley stays silent and inactive.

Discussion positions are mapped from the review revision to your working files,
including unsaved buffer edits, using Git or Arc as appropriate. Local edits
refresh positions without fetching the review again, and separate checkouts keep
independent positions. If revision content is unavailable, Parley shows stale
approximations and reports the reason.

New comments require a clean file with no unsaved edits and a local HEAD matching
the review revision. These checks run again when you submit; a failed check keeps
your draft. Other Arcanum API limitations still apply.

## Telescope

When `telescope = true` (the default) and Telescope is installed, Parley loads two extensions:

```lua
-- Show all discussions in the current PR
require("telescope").extensions.parley_discussions.parley_discussions()
-- Show all discussions in the current PR limited to the current file
require("telescope").extensions.parley_discussions_file.parley_discussions_file()
```

## Quickfix

Populate the quickfix list with all discussions from the active review:

```vim
:Parley quickfix
```

Parley uses review-wide anchor mappings when available, so quickfix entries jump to
best-effort local buffer lines across files.


## Statusline

Parley exposes a statusline component:

```lua
require("parley").statusline()
```

Example with lualine:

```lua
{
  "nvim-lualine/lualine.nvim",
  opts = function(_, opts)
    table.insert(opts.sections.lualine_c, function()
      return require("parley").statusline()
    end)
  end,
}
```

When Parley is inactive for the current buffer, the component returns an empty string.

## Configuration

All options have sensible defaults. A minimal setup needs no arguments:

```lua
require("parley").setup({})
```

Common options:

```lua
require("parley").setup({
  refresh_interval = 120,          -- seconds (0 = disabled)
  telescope = false,               -- disable Telescope extensions
  keymaps = {
    buf_next    = "]c",   -- "" to disable
    buf_prev    = "[c",
    review_next = "]C",
    review_prev = "[C",
  },
})
```

See `:help parley-configuration` for the full reference with all defaults.

Requests to GitHub are made through the standard `gh` CLI.
Arcanum requests are make through `arc` CLI.
See `:help parley-providers` for details.

## Health Check

Run:

```vim
:checkhealth parley
```

This checks:

- Neovim version
- `git` and `gh` availability
- `arc` availability
- `plenary.async`
- cache directory setup
- optional integrations
- whether the current buffer is in a supported repository
- whether GitHub authentication can be resolved

## Documentation

Full reference documentation is available inside Neovim:

```vim
:help parley.nvim
```

## Development checks

Run `make test`, `make format`, `make format-check`, and `make lint` before
submitting changes. Architecture tests discover every production Lua file under
`lua/` and `plugin/`. Add each new file to exactly one layer's `modules` list in
[policy.json](policy.json); remove the assignment when deleting a file. Tests and
build scripts are outside that production inventory.

All concrete provider code belongs under `lua/parley/providers/` in the
`providers` layer. Shared code must delegate through contracts and registration.
The only permitted shared import into that directory is setup's import of
`parley.providers`. Provider code may use its declared shared infrastructure
layers. Layer dependencies must remain acyclic; external API capabilities remain
explicit, including the narrow `ui_notify` capability for provider notifications.

Use literal, dotted module names with `require("module")`, `require "module"`,
or `pcall(require, "module")`. Computed imports, untracked loader aliases, and
source-file loaders fail the checker. The existing health `M._require` seam is
tracked specifically, and its protected calls must also use literal names.
Missing modules in Parley's namespaces fail even if loaded through `pcall`.

Checker utilities and regression fixtures live under `tests/support/` and
`tests/parley/policy_checker_spec.lua`. These are structural checks for supported
Lua import forms, not a sandbox or a semantic proof: copied provider algorithms,
command tables, and arbitrary runtime indirection still require review and
provider-independent behavior tests.

## Roadmap

- `diffview.nvim` integration
- real thread resolved state for GitHub via GraphQL
- PR-level review actions (resolve / unresolve)
