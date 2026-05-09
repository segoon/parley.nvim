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
- Navigate commented lines with `]c` and `[c`
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
4. Run `:Parley refresh` once, or just re-enter the buffer.
5. Use `]c` and `[c` to move between commented lines.
6. Use `:Parley discussion toggle` to open the discussion window for the current line.

If no matching PR is found, Parley stays silent and inactive.

## Usage

### Commands

| Command | Description |
| --- | --- |
| `:Parley refresh` | Force a refresh for the current buffer |
| `:Parley discussion toggle` | Toggle the discussion window |
| `:Parley discussion new` | Open a draft for a new comment |
| `:Parley discussion reply` | Reply to the current thread |
| `:Parley comment react` | React to the selected comment |
| `:Parley comment edit` | Edit the selected comment |
| `:Parley comment delete` | Delete the selected comment |

See `:help parley-commands` for the full list.

### Keymaps

| Key | Context | Description |
| --- | --- | --- |
| `]c` / `[c` | global | Jump between commented lines |
| `q` | discussion | Close window |
| `r` | discussion | Reply |
| `R` | discussion | React |
| `e` | discussion | Edit comment |
| `d` | discussion | Delete comment |
| `s` / `<C-s>` | draft | Submit |

See `:help parley-keymaps` for the full reference.

## Telescope

When `telescope = true` and Telescope is installed, Parley loads two extensions:

- `parley_discussions`
- `parley_discussions_file`

Examples:

```lua
require("telescope").extensions.parley_discussions.parley_discussions()
require("telescope").extensions.parley_discussions_file.parley_discussions_file()
```

The first shows all discussions in the current PR. The second limits results to the current file.

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
    next_comment = "]c",           -- "" to disable
    prev_comment = "[c",
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

## Current Limitations

- GitHub is the only built-in provider today
- Only regular file buffers are active right now
- `diffview.nvim` integration is planned, not currently active
- GitHub REST review comments do not expose thread resolved state
- Because of that, unresolved counts are currently approximate
- Resolve and unresolve are not available yet for GitHub
- PR-level review submission exists in the provider layer, but does not yet have a user-facing workflow

## Roadmap

- `diffview.nvim` integration
- additional providers
- real thread resolved state for GitHub via GraphQL
- PR-level review actions

## Why Parley?

Existing plugins often focus on the full hosting platform surface.

Parley focuses on one thing: line-level review discussion directly in the editing flow.
