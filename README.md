# parley.nvim

Inline pull request discussions for Neovim.

`parley.nvim` lets you read and act on PR review threads directly from the buffer: inline signs, virtual text, a floating discussion view, replies, edits, reactions, and navigation without leaving Neovim.

> [!WARNING]
> Early-stage plugin.
> Current support includes GitHub (Git) and Arcanum (Arc) in regular file buffers. Diffview integration is planned; live Arcanum deployment compatibility remains unverified.

## Features

- Detect the active PR for the current branch on GitHub / Yandex Arcanum
- Render commented lines with signs and virtual text
- Open a floating discussion window for the current line
- Add new top-level comments on a line or range
- Reply to, edit, delete, and react to comments
- Navigate commented lines within a buffer (`]c` / `[c`) or across the whole review (`]C` / `[C`)
- Fill quickfix with file-associated discussions and their available positions
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
- [`nvim-lua/plenary.nvim`](https://github.com/nvim-lua/plenary.nvim)

GitHub requires `git` and `gh`. Arcanum requires `arc`, `curl`, and HTTPS access
to its configured API host (default `arcanum.yandex.net`).

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
2. For GitHub, configure credentials with `gh auth login` or a supported token environment variable. For Arcanum, configure an OAuth token as described below.
3. Open a regular file inside a Git or Arc repository whose branch has an open PR. Arcanum requires a remote branch.
4. Use `]c` / `[c` to move between commented lines in the buffer, or `]C` / `[C` to jump across all files in the review.
5. Use `:Parley discussion toggle` to open the discussion window for the current line.
6. Use `:Parley quickfix` for file-associated discussions or `:Parley discussion list` for every thread.

If no matching PR is found, Parley stays silent and inactive.

Discussion positions are mapped from the review revision to your working files,
including unsaved buffer edits, using Git or Arc as appropriate. Local edits
refresh positions without fetching the review again, and separate checkouts keep
independent positions. If revision content is unavailable, Parley shows stale
approximations and reports the reason.

New comments require a clean file with no unsaved edits and a local HEAD matching
the review revision. These checks run again when you submit; a failed check keeps
your draft. Other Arcanum API limitations still apply.

Use `:Parley discussion list` to browse every thread without Telescope. Arcanum
nested replies and issue states are preserved. General, whole-file, old-side,
and historical threads open in the discussion float without a guessed line.
Replies and edits/deletions of your own comments remain available. Only open
issues contribute to the unresolved count.

Use `:Parley discussion resolve` or `:Parley discussion reopen` to change an
Arcanum issue between open and resolved. These commands use the selected thread
or offer the threads at the source cursor. They preserve drafts and refresh the
issue state. Dropped, non-issue, unknown, and incomplete threads cannot transition.
GitHub resolution remains unavailable. Unsupported provider actions explain why
before you compose or choose them; see `:help parley-provider-capabilities`.

Arcanum reactions offer thumbs up, thumbs down, and heart; other existing codes
remain readable and removable by their author. AI comments allow one reaction
per account; remove an existing reaction explicitly before replacing it.

Use `:Parley review actions` for Ship, Sticky ship, Unship, Block merge, and
Unblock merge. The confirmation shows the PR, loaded revision, and current verdict.
Sticky ship approves future diffs until withdrawn. No review message is bundled.
Reactions and withdrawals require `GENERIC_WRITE`; ship and block additions
require `REVIEW_REQUEST_SHIP`. Server permissions remain authoritative.
The active diff is rechecked after confirmation, but the API cannot atomically
pin it during the write. Review data failures show status `unknown` and disable
review actions until refresh; discussions remain available.

Arcanum credentials are read from `ARCANUM_TOKEN`, then `ARC_OAUTH_TOKEN`, then
`ARC_TOKEN_PATH`, then `~/.arc/token`. An unreadable or empty explicit token file
is an error. Review loading verifies the token's API account before showing cached
discussions; failed verification stops loading, and the local Arc login is never
used to guess ownership. Credential changes require a refreshed session.

Discovery searches successive prefix-result pages for the exact remote branch.
Without a remote branch, Parley remains inactive. Configure a hostname with an
optional port under `providers.arcanum.host`; do not include a URL scheme or path.

## Telescope

When `telescope = true` (the default) and Telescope is installed, Parley loads two extensions:

```lua
-- Show all discussions in the current PR
require("telescope").extensions.parley_discussions.parley_discussions()
-- Show all discussions in the current PR limited to the current file
require("telescope").extensions.parley_discussions_file.parley_discussions_file()
```

## Quickfix

Populate the quickfix list with file-associated discussions from the active review:

```vim
:Parley quickfix
```

Parley uses review-wide anchor mappings when available. Entries with unavailable
positions remain invalid rows; general discussions are omitted. Use
`:Parley discussion list` or the review-wide Telescope picker to access every thread.


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
  refresh_interval = 300,          -- seconds between polling rounds; 0 disables
  telescope = false,              -- disable Telescope extensions
  keymaps = {
    buf_next    = "]c",   -- "" to disable
    buf_prev    = "[c",
    review_next = "]C",
    review_prev = "[C",
  },
})
```

See `:help parley-configuration` for the full reference with all defaults.
`refresh_interval` defaults to 300 seconds; set it to `0` to disable polling.
Positive values must be whole seconds within the timer range. Polling refreshes
already-loaded reviews visible in the current tab, including discussion/input
windows, once per shared review. It skips reviews with an active read or write.

Polling pauses when Neovim loses focus. The first round starts a full interval
after setup or focus returns; subsequent rounds wait a full interval after the
previous round finishes. Reviews are refreshed sequentially without catch-up bursts.
Hidden reviews and branches without an active PR are not polled. Buffer entry and
`:Parley refresh` still discover reviews, and writes still refresh remote state.

Background refresh is quiet: no progress popups or error notifications. Available
review data and drafts remain visible, with existing identity checks still applied.
Use `:Parley refresh` for an explicit progress-enabled refresh and error reporting.
Repeated `setup()` replaces the polling schedule; editor shutdown stops it.

Requests to GitHub are made through the standard `gh` CLI.
Arcanum uses asynchronous HTTPS. Its default request budget is 10 seconds,
including queueing and retry waits, with request starts spaced one second apart.
Comment and reply retries are opt-in via
`providers.arcanum.idempotent_write_retries = true`; enable this only after
confirming the deployed server supports idempotency keys. After an uncertain
write failure or cancellation, check the review before resubmitting your draft.
See `:help parley-providers` for details.

## Health Check

Run:

```vim
:checkhealth parley
```

This checks:

- Neovim version
- provider-specific tools (`git`/`gh` or `arc`/`curl`)
- `plenary.async`
- cache directory setup
- optional integrations
- whether the current buffer is in a supported repository
- local credential availability and, for Arcanum, the token source and configured host

Health checks remain local-only and do not verify credentials with the server.

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
- GitHub thread resolution/reopening via GraphQL
- optional Arcanum drafts/publication, suggestions, and additional comment anchors

See [TODO.md](TODO.md) for remaining work and
[ARCANUM_COMPATIBILITY.md](ARCANUM_COMPATIBILITY.md) for current Arcanum support
and validation limits.
