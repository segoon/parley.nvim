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
4. Run `:ParleyRefresh` once, or just re-enter the buffer.
5. Use `]c` and `[c` to move between commented lines.
6. Use `:Parley discussion toggle` to open the discussion window for the current line.

If no matching PR is found, Parley stays silent and inactive.

## Usage

### Commands

| Command | Description |
| --- | --- |
| `:ParleyRefresh` | Force a refresh for the current buffer |
| `:Parley discussion open` | Open the discussion window for the current line |
| `:Parley discussion close` | Close the discussion window |
| `:Parley discussion toggle` | Toggle the discussion window |
| `:Parley discussion new` | Open a draft for a new top-level comment |
| `:'<,'>Parley discussion new` | Create a new comment for the selected line range |
| `:Parley discussion reply` | Reply to the selected or current comment thread |
| `:Parley comment react` | Add or remove a reaction on the selected comment |
| `:Parley comment edit` | Edit the selected comment |
| `:Parley comment delete` | Delete the selected comment |
| `:Parley nav next` | Jump to the next commented line |
| `:Parley nav prev` | Jump to the previous commented line |

### Default keymaps

| Key | Description |
| --- | --- |
| `]c` | Jump to next commented line |
| `[c` | Jump to previous commented line |

### Discussion window keys

| Key | Description |
| --- | --- |
| `q` | Close discussion window |
| `r` | Reply |
| `R` | React |
| `e` | Edit selected comment |
| `d` | Delete selected comment |

### Draft window keys

| Key | Description |
| --- | --- |
| `q` | Close draft |
| `s` | Submit draft in normal mode |
| `<C-s>` | Submit draft in insert mode |
| `C` | Cancel in-flight request |

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

```lua
require("parley").setup({
  refresh_interval = 300,
  cache_dir = vim.fn.stdpath("cache") .. "/parley",
  telescope = true,
  signs = {
    enabled = true,
    text = "▐",
  },
  virtual_text = {
    enabled = true,
    max_width = 60,
  },
  float = {
    border = "rounded",
    max_width = 80,
    max_height = 30,
  },
  progress = {
    enabled = true,
    border = "rounded",
    max_width = 60,
    max_height = 8,
    success_timeout = 1200,
    failed_timeout = 2500,
    cancelled_timeout = 1200,
    margin_bottom = 1,
    margin_right = 2,
    spinner_interval = 100,
  },
  keymaps = {
    next_comment = "]c",
    prev_comment = "[c",
  },
  providers = {
    github = {
      timeout_ms = 5000,
      retry_count = 2,
      retry_base_delay_ms = 250,
      retry_max_delay_ms = 2000,
    },
  },
})
```

GitHub authentication is resolved through the standard `gh` CLI configuration and environment variables.

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
- broader docs and vim help

## Why Parley?

Existing plugins often focus on the full hosting platform surface.

Parley focuses on one thing: line-level review discussion directly in the editing flow.
