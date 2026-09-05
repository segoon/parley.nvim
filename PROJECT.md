# parley.nvim

A Neovim plugin for reading, writing, and navigating pull request discussions
without leaving the editor. Built-in providers support GitHub with Git and
Arcanum with Arc in regular file buffers. Diffview integration is a future goal.

## Problem and goals

Developers switch between a browser and their editor to read review comments,
respond to feedback, and track unresolved threads. Parley brings those discussions
into the working file, with provider-independent navigation and composition.

The audience is developers reviewing code and authors responding to reviews.
The priority is a responsive keyboard-driven UI, clear action availability, and
preservation of the user's intent and drafts when an operation fails. The plugin
focuses on discussions rather than a complete hosting-platform client for issues,
notifications, repository browsing, or PR administration.

## Implemented user scenarios

### Read and navigate a review

1. Open a regular file in a Git or Arc working copy whose branch has an open PR.
   Arcanum discovery requires a remote branch and follows search pages until it
   finds an exact match. Without a matching review, Parley remains inactive.
2. Signs and virtual text show discussions with usable local positions. Navigate
   within a file with `]c` / `[c` or across the review with `]C` / `[C`.
3. Run `:Parley discussion open` or `:Parley discussion toggle` at a commented
   line. If multiple threads share the line, choose one in the built-in picker.
4. Use `:Parley discussion list` for every thread, including general, whole-file,
   old-side, historical, and unavailable-location discussions. Optional Telescope
   extensions list all discussions or those associated with the current file.
5. File-associated quickfix entries use available mappings; unavailable locations
   remain invalid rows. General discussions are accessed through the pickers.

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
4. Failed lookups or validation preserve the draft. Inline posting never silently
   changes into a general comment. After an uncertain write or cancellation,
   check the review before retrying; cancelling a process cannot undo a server write.

Arcanum inline creation uses the loaded diff. Unlike review verdict actions, it
does not fetch the active diff again at submission time. Refresh to load a newer diff.

### Resolve issues and react

- `:Parley discussion resolve` and `:Parley discussion reopen` transition complete
  Arcanum root issues between open and resolved. General and unavailable-location
  threads support these actions too. Dropped, non-issue, unknown, and incomplete
  threads cannot transition. GitHub resolution/reopening remains planned.
- `:Parley comment react` opens provider-owned choices. GitHub retains its reaction
  vocabulary. Arcanum offers thumbs up, thumbs down, and heart, plus removal of
  other reactions already added by the viewer. Its writes preserve the add/remove
  intent selected in the picker. AI comment conflicts require explicit removal
  of an existing reaction before replacement.
- Capability checks explain unsupported actions before composition or submission.
  Successful, conflicting, and uncertain action refreshes retain discussion drafts.
  Capabilities describe implementation support; server permissions still apply.

### Review verdicts and status

1. Run `:Parley review actions` for Arcanum ship, sticky ship, unship, block merge,
   or unblock merge. There is no default keymap or bundled review message.
2. Confirm the PR, loaded revision, and current viewer verdict. Sticky approval
   includes future diffs; withdrawals require the corresponding viewer verdict.
3. The provider rechecks the active diff before writing. The API cannot atomically
   pin the expected diff, so an intervening update can still change the target.
4. Status uses reviewer verdicts and remaining approval requirements. A failed or
   malformed status read yields unknown and disables review actions while leaving
   discussions readable. Only open issues contribute to the unresolved count.

GitHub's provider-level `submit_review` supports approve/request_changes/comment
with a body. The explicit action picker is currently Arcanum-only.

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
old-side, historical, and unlocated threads do not receive fabricated positions.
Remote review data can be shared across checkouts, but local mappings are separate.

### Authentication and caching

GitHub uses `gh` for API requests and provider-specific credential resolution.
Arcanum uses asynchronous HTTPS with credentials from `ARCANUM_TOKEN`,
`ARC_OAUTH_TOKEN`, `ARC_TOKEN_PATH`, or `~/.arc/token`, in that order. An unreadable
explicit token file fails rather than selecting another credential source.
Arcanum verifies the API account before restoring cached reviews; local Arc login
is diagnostic metadata and never establishes comment ownership.

Disk review caches follow Neovim's XDG cache location and are isolated by provider,
host, repository, and account fingerprint. Credentials are not stored in cache
keys. Identity changes discard obsolete results. Stable identity is required for
persistent caching; otherwise review state remains isolated and temporary.

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

All remote operations are asynchronous. Arcanum requests have a shared per-process
host/credential queue, request spacing, 429 cooldowns, and a deadline covering
queueing, attempts, and retry waits. These controls do not coordinate other clients.
Create/reply retries require explicit opt-in after deployment idempotency support
is verified; other mutations are not automatically retried. GitHub has its own
retry configuration; broader rate-limit-header handling remains planned.

Errors are reported with actionable messages. Cached data may remain available
after fetch failures, but failed account verification does not restore obsolete
ownership. Uncertain writes preserve drafts and require checking remote state.
Health checks inspect local tools, credentials, configuration, and repository state;
they do not verify authentication or deployment compatibility over the network.

## UI and implementation choices

| Concern | Current implementation |
|---|---|
| Language and minimum editor | Lua with LuaCATS; Neovim 0.10 |
| Async execution | `plenary.async`; cancellable callback starters for supported writes |
| API transport | GitHub: `gh`; Arcanum: curl through Plenary |
| Windows and inline rendering | Native Neovim windows, buffers, extmarks, signs, and virtual text |
| Markdown | Optional `render-markdown.nvim` integration |
| Discussion selection | Built-in pickers; optional Telescope extensions |
| Statusline | Provider label, PR number, review status, and unresolved count |
| Configuration | `require("parley").setup({})`; lazy.nvim or another plugin manager |
| Testing | Plenary tests with mocked providers/HTTP and real Neovim UI fixtures |

## Future goals and remaining risks

- Diffview should eventually support discussion rendering, selection, navigation,
  and inline composition in its diff buffers. Context detection exists, but the
  current review services accept only regular file buffers. Revision/side mapping
  and float placement need a separately designed and tested integration.
- GitHub resolution needs GraphQL integration.
- Optional Arcanum extensions include drafts/publication, old-side or whole-file
  comment creation, and suggestions. Reading existing threads does not imply
  these creation workflows are supported.
- Additional hosting/VCS integrations, richer Telescope previews, and remaining
  quality work are tracked in TODO.md.
- Mocked success does not establish live deployment parity, token authorization,
  idempotency support, or the absence of active-diff races. Large local changes
  also reduce the precision of line mappings.

See ARCANUM_COMPATIBILITY.md for current Arcanum contracts and validation limits.
