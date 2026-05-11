# parley.nvim

Inline pull request discussions for Neovim.

`parley.nvim` lets you read and act on PR review threads directly from the buffer: inline signs, virtual text, a floating discussion view, replies, edits, reactions, and navigation without leaving Neovim.

> [!WARNING]
> Early-stage plugin.
> Current support is GitHub only, regular file buffers only, and some planned features are not exposed yet.

## Features

- Detect the active PR for the current branch on GitHub remotes
- Render commented lines with signs and virtual text
- Open a floating discussion window for the current line
- Add new top-level comments on a line or range
- Reply to, edit, delete, and react to comments
- Navigate commented lines within a buffer (`]c` / `[c`) or across the whole review (`]C` / `[C`)
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
2. Authenticate GitHub CLI with `gh auth login`.
3. Open a file inside a git repository whose current branch has an open PR.
4. Use `]c` / `[c` to move between commented lines in the buffer, or `]C` / `[C` to jump across all files in the review.
5. Use `:Parley discussion toggle` to open the discussion window for the current line.

If no matching PR is found, Parley stays silent and inactive.

## Telescope

When `telescope = true` (the default) and Telescope is installed, Parley loads two extensions:

```lua
-- Show all discussions in the current PR
require("telescope").extensions.parley_discussions.parley_discussions()
-- Show all discussions in the current PR limited to the current file
require("telescope").extensions.parley_discussions_file.parley_discussions_file()
```


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

GitHub authentication is resolved through the standard `gh` CLI configuration and environment variables. See `:help parley-providers` for details.

## Health Check

Run:

```vim
:checkhealth parley
```

This checks:

- Neovim version
- `git` and `gh` availability
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

## Roadmap

- `diffview.nvim` integration
- Arcanum integration
- real thread resolved state for GitHub via GraphQL
- PR-level review actions (resolve / unresolve)
