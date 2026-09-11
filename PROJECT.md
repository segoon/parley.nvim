# parley.nvim

A Neovim plugin for reading, writing, and navigating pull request discussions
without leaving the editor. Built-in integrations support GitHub with Git and
Arcanum with Arc; their behavior and limitations are documented in
GITHUB_COMPATIBILITY.md and ARCANUM_COMPATIBILITY.md.

## Problem and goals

Developers switch between a browser and their editor to read review comments,
respond to feedback, and track unresolved threads. Parley brings those discussions
into the working file, with provider-independent navigation and composition.

The audience is developers reviewing code and authors responding to reviews. The
priority is a responsive keyboard-driven UI, clear action availability, and
preservation of the user's intent and drafts when an operation fails. The plugin
focuses on discussions rather than a complete hosting-platform client for issues,
notifications, repository browsing, or PR administration.

## Implemented user scenarios

### Read and navigate a review

1. Open a regular file in a supported working copy whose branch has an open review.
   Without a matching review, Parley remains inactive.
2. Signs and virtual text show discussions with usable local positions. Navigate
   within a file with `]c` / `[c` or across the review with `]C` / `[C`.
3. Run `:Parley discussion open` or `:Parley discussion toggle` at a commented
   line. If multiple threads share the line, choose one in the built-in picker.
4. Use `:Parley discussion list` for every thread, including general, whole-file,
   old-side, historical, and unavailable-location discussions. Optional Telescope
   extensions list all discussions or those associated with the current file.
5. File-associated quickfix entries use available mappings; unavailable locations
   remain invalid rows. General discussions are accessed through the pickers.
6. Append `unresolved` to buffer/review navigation or the built-in discussion list
   to work only with open issues. Telescope pickers accept the same filter option.
7. Run `:Parley view` to open the active review in the system browser. Run
   `:Parley discussion view` to open the selected thread's canonical provider
   link, or choose a thread at the source cursor when none is selected. Run
   `:Parley comment view`, or press `gx` in the discussion float, to open the
   selected comment's exact provider-owned link.

The discussion float retains the selected thread across refreshes. It does not
automatically open or follow the source cursor. Replies retain their parent IDs,
and a generic tree renderer handles nested and incomplete discussion graphs.

### Reply, create, edit, and delete comments

1. In the discussion float, select a comment and press `r` to compose a reply,
   `e` to edit your own comment, or `d` to request deletion with confirmation.
2. Run `:Parley discussion new` on a line or visual range for a top-level comment.
   The local HEAD must match the loaded review revision, the file must be clean,
   and every selected line must belong to the changed new side of the review.
3. Compose Markdown in the input window; submit with `s` in normal mode or
   `<C-s>` in insert mode. Checks run before composition and again on submission.
4. Replies and new discussions appear immediately as pending comments. The
   composer closes while the request runs; success replaces the pending entry
   with provider data and refreshes the review quietly in the background.
5. Definite failures and cancellations remove the pending entry and restore the
   draft. Failed lookups or validation also preserve the draft. Inline posting
   never silently changes into a general comment. After an uncertain write or cancellation,
   check the review before retrying; cancelling a process cannot undo a server write.

### Resolve discussions and react

- `:Parley discussion resolve` and `:Parley discussion reopen` transition a
  discussion when the active provider and discussion state support it.
- `:Parley comment react` opens provider-owned choices and preserves the explicit
  add/remove intent selected in the picker.
- Capability checks explain unsupported actions before composition or submission.
  Successful, conflicting, and uncertain action refreshes retain discussion drafts.
  Capabilities describe implementation support; server permissions still apply.

### Review verdicts and status

Providers can expose explicit review actions, bundled review submissions, or both.
The UI checks capabilities before composition, confirms provider-defined actions,
and refreshes review state after a write. Failed or malformed status reads degrade
to an unknown state without hiding readable discussions.

## Architecture and reliability

### Provider and VCS boundaries

All concrete hosting and VCS implementations live under `lua/parley/providers/`.
Shared workflows use provider contracts, capabilities, and VCS adapters. Built-in
hosting providers are GitHub and Arcanum; built-in VCS adapters are Git and Arc.
Custom integrations register their own implementations after `setup()`.

Discussion anchors retain kind, side, paths, revision, and diff identity. Mapping
compares the review head's file contents with the loaded buffer, including unsaved
edits, or the working-tree file. Debounced local edits update positions without
fetching the API. Missing revision content produces visibly stale approximations;
historical and unlocated threads do not receive fabricated positions. Remote review
data can be shared across checkouts, but local mappings are separate.

### Authentication and caching

Each provider owns credential resolution and stable account identity. Disk review
caches follow Neovim's XDG cache location and are isolated by provider, host,
repository, and account fingerprint. Credentials are not stored in cache keys.
Identity changes discard obsolete results. Without stable identity, review state
remains isolated and temporary instead of entering the persistent cache.

### Refresh and transport

Refresh runs asynchronously on buffer entry, explicit `:Parley refresh`, after
writes, and in periodic rounds. `refresh_interval` defaults to 300 seconds; `0`
disables polling. Each round refreshes already-loaded reviews visible in the
current tab once, sequentially, skipping reviews with active reads or writes.
Discussion/composer windows count toward source-review visibility. Branches
without an active review are discovered on buffer entry or manual refresh.

Polling pauses while Neovim is unfocused. Setup, focus regain, and completed
rounds each wait a full interval before another round. Missed intervals do not
accumulate. Background errors are quiet; snapshots and drafts retain their existing
failure/identity protections. Repeated setup replaces the timer and shutdown stops
it. Manual refresh keeps its progress and error reporting.

All remote operations are asynchronous. Providers own transport, retry, pacing,
and authorization behavior behind the shared interface. Errors use actionable
messages. Cached data may remain available after fetch failures, while identity
changes reject obsolete results. Uncertain writes preserve drafts and require the
user to check remote state. Health checks remain local and do not establish live
authentication or deployment compatibility.

## UI and implementation choices

| Concern | Current implementation |
|---|---|
| Language and minimum editor | Lua with LuaCATS; Neovim 0.10 |
| Async execution | `plenary.async`; cancellable callback starters for supported writes |
| Provider transport | Provider-owned asynchronous adapters |
| Windows and inline rendering | Native Neovim windows, buffers, extmarks, signs, and virtual text |
| Markdown | Optional `render-markdown.nvim` integration |
| Discussion selection | Built-in pickers; optional Telescope extensions |
| Statusline | Provider label, PR number, review status, and unresolved count |
| Configuration | `require("parley").setup({})`; lazy.nvim or another plugin manager |
| Testing | Plenary tests with mocked providers/HTTP and real Neovim UI fixtures |

## Limitations and future goals

- Diffview integration covers rendering, hover, new-side comment creation,
  cross-file navigation, and `:Parley diffview open|close|toggle`. Availability of
  ranges and old-side metadata depends on the active VCS and provider contracts.
- Reading an existing discussion location does not imply that creating a new
  comment at the same kind of location is supported.
- Additional integrations, richer Telescope previews, and remaining quality work
  are tracked in TODO.md.
- Mocked success does not establish live deployment parity, authorization, or the
  absence of remote-state races. Large local changes also reduce mapping precision.

Provider contracts and limitations:

- [GitHub compatibility](GITHUB_COMPATIBILITY.md)
- [Arcanum compatibility](ARCANUM_COMPATIBILITY.md)
