# parley.nvim

Inline pull request discussions for Neovim.

`parley.nvim` lets you read and act on PR review threads directly from the buffer: inline signs, virtual text, a floating discussion view, replies, edits, reactions, and navigation without leaving Neovim.

> [!WARNING]
> Early-stage plugin.
> Current support includes GitHub (Git) and Arcanum (Arc) in regular file buffers, plus diffview.nvim diff buffers.

## Features

- Detect the active PR for the current branch on GitHub / Yandex Arcanum
- Render commented lines with signs and virtual text
- Open a floating discussion window for the current line
- Open the active review, current discussion, or selected comment in the system browser
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

Required:

- Neovim `>= 0.10`
- [`nvim-lua/plenary.nvim`](https://github.com/nvim-lua/plenary.nvim)

GitHub requires `git` and `gh`. Arcanum requires `arc`, `curl`, and HTTPS access
to its configured API host (default `arcanum.yandex.net`).

Optional:

- [`nvim-telescope/telescope.nvim`](https://github.com/nvim-telescope/telescope.nvim) — enables the `parley_discussions` / `parley_discussions_file` pickers (see [Telescope](#telescope))
- [`MeanderingProgrammer/render-markdown.nvim`](https://github.com/MeanderingProgrammer/render-markdown.nvim) — renders comment bodies as Markdown in the discussion window
- [diffview.nvim](https://github.com/sindrets/diffview.nvim) — when installed, parley automatically renders PR discussions, and lets you create new comments, inside its diff buffers, plus comment-count badges in its file panel (see [Diffview integration](#diffview-integration)). No extra configuration is required beyond having the plugin loaded; disable with `diffview = { enabled = false }`. Verified against both upstream and the [`mistricky/diffview-plus.nvim`](https://github.com/mistricky/diffview-plus.nvim) fork; not verified against other forks.

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
    -- "sindrets/diffview.nvim",
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
7. Use `:Parley view` to open the review in your browser, `:Parley discussion view`
   to open the selected discussion, or `:Parley comment view` to open its selected
   comment's canonical provider link.

If no matching PR is found, Parley stays silent and inactive.

Discussion positions are mapped from the review revision to your working files,
including unsaved buffer edits, using Git or Arc as appropriate. Local edits
refresh positions without fetching the review again, and separate checkouts keep
independent positions. If revision content is unavailable, Parley shows stale
approximations and reports the reason.

New comments require a clean file with no unsaved edits and a local HEAD matching
the review revision. These checks run again on submission and preserve the draft
on failure. Replies and new discussions appear immediately with a sending marker;
the composer closes while the request runs. Success replaces the temporary entry
with provider data and refreshes quietly in the background. A definite failure or
cancellation removes it and restores the draft. Arcanum creates comments only on
the loaded diff's new side.

Use `:Parley discussion list` to browse every thread without Telescope. Arcanum
preserves nested replies and distinct issue states. General, whole-file, old-side,
historical, and otherwise unavailable threads open without a fabricated position.
Append `unresolved` to show only open issues: `:Parley discussion list unresolved`.
The same filter works with buffer-local and review-wide navigation, for example
`:Parley nav buf-next unresolved` and `:Parley nav review-prev unresolved`.

Use `:Parley discussion resolve` or `:Parley discussion reopen` to change a
supported issue or review thread. Arcanum transitions complete root issues;
dropped, non-issue, unknown, and incomplete threads cannot transition. Unsupported
actions explain why before composition; see `:help parley-provider-capabilities`.

Use `:Parley view` to open the active review with the system URL handler.
`:Parley discussion view` opens the thread selected in the discussion float, or
uses the current-line chooser when no thread is selected. Discussion links are
opened only when the provider returned an exact canonical URL; they never fall
back to the general review page.
`:Parley comment view` opens the selected comment's exact provider URL. In the
discussion window, `gx` invokes the same action. Missing comment links are
reported and do not fall back to the discussion URL.

Arcanum's `:Parley review actions` provides Ship, Sticky ship, Unship, Block merge,
and Unblock merge. It confirms the loaded revision and rechecks the active diff,
but the API cannot atomically pin that diff during the write. Server permissions
remain authoritative; unavailable review data disables these actions without
hiding discussions.

Arcanum credentials are read from `ARCANUM_TOKEN`, `ARC_OAUTH_TOKEN`,
`ARC_TOKEN_PATH`, or `~/.arc/token`, in that order. Review loading verifies the API
account before restoring cached ownership; the local Arc login is diagnostic only.
Discovery requires an exact remote-branch match. See `:help parley-provider-arcanum`
for permissions, configuration, transport behavior, and detailed limitations.

## Telescope

When `telescope = true` (the default) and Telescope is installed, Parley loads two extensions:

```lua
-- Show all discussions in the current PR
require("telescope").extensions.parley_discussions.parley_discussions()
-- Show all discussions in the current PR limited to the current file
require("telescope").extensions.parley_discussions_file.parley_discussions_file()
-- Pass the same filter to either picker to show only open issues
require("telescope").extensions.parley_discussions.parley_discussions({ filter = "unresolved" })
```

## Quickfix

Populate the quickfix list with file-associated discussions from the active review:

```vim
:Parley quickfix
```

Parley uses review-wide anchor mappings when available. Entries with unavailable
positions remain invalid rows; general discussions are omitted. Use
`:Parley discussion list` or the review-wide Telescope picker to access every thread.


## Diffview integration

Optional; requires [diffview.nvim](https://github.com/sindrets/diffview.nvim) to be installed and loaded. No extra setup call is needed — parley listens for diffview's `User` autocmds automatically once both plugins are set up.

Run `:Parley diffview open` to open diffview scoped to the active review's base...head range — no need to look up or type the commit range yourself. `:Parley diffview close` closes it; `:Parley diffview toggle` opens or closes depending on whether a view is already open on the current tab. Automatic range construction is Git-only because the Arc VCS adapter has no diffview equivalent; attaching discussions to an existing eligible diffview buffer is provider-independent.

Whichever way you open it, when a diffview diff buffer showing the PR's head revision is current, parley:

- Renders the same signs / virtual text / hover previews as regular buffers, for discussions anchored to that file
- Lets you add a new top-level comment at the cursor line with `<leader>pc` (configurable, see `keymaps.diffview_new_comment` below)
- Shows a 💬 comment-count badge (with `!` for unresolved threads) next to changed files in diffview's file panel
- Supports the full discussion workflow — reply, edit, resolve/reopen, react — the same as in a regular buffer
- `]C`/`[C` (`:Parley nav review-next/-prev`) hop between files across the whole review, switching diffview's active file and file-panel selection along with the cursor

Verified against both [upstream diffview.nvim](https://github.com/sindrets/diffview.nvim) and the [`mistricky/diffview-plus.nvim`](https://github.com/mistricky/diffview-plus.nvim) fork; not verified against other forks. One difference: file-panel badges refresh live on file selection and staging under the fork (which fires extra `User` events upstream doesn't), but only after layout changes under plain upstream diffview.nvim.

The head/"new" side is always supported. The base/"old" side renders read-only when a comment is actually anchored there — currently only Arcanum ever anchors comments to the old side (GitHub's provider mapping doesn't capture that data); creating a *new* comment on the old side isn't supported by either provider's write path. Disable the integration entirely with:

```lua
require("parley").setup({
  diffview = { enabled = false },
})
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
  refresh_interval = 300,          -- seconds between polling rounds; 0 disables
  telescope = false,              -- disable Telescope extensions
  signs = {
    resolved = "✅",
    unresolved = "❗",
    comment = "💬",
  },
  keymaps = {
    buf_next    = "]c",   -- "" to disable
    buf_prev    = "[c",
    review_next = "]C",
    review_prev = "[C",
  },
})
```

When several discussions share a line, unresolved discussions take precedence,
followed by comments and resolved discussions. Each sign must occupy at most two
display cells. The former `signs.text` option remains available as a compatibility
override that uses one glyph for every state.

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
- cache directory setup and used size
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

- optional Arcanum drafts/publication, suggestions, and additional comment anchors

See [TODO.md](TODO.md) for remaining work and the compatibility references for
current provider behavior and validation limits:

- [GitHub compatibility](GITHUB_COMPATIBILITY.md)
- [Arcanum compatibility](ARCANUM_COMPATIBILITY.md)
