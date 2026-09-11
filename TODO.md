# Remaining work

- checkhealth cache_dir: add used size like (xxx Mb)
- on reply/new discussion: immediatelly add the comment, refresh in background

- :Parley view - open browser with PR
- :Parley discussion view - open browser on the current discussion page
- :Parley diffview open - must close current herdr sidebar (if any), undo on close

## Review workflows

- Optional Arcanum drafts/publication, suggestions, and old-side/whole-file creation
- Validate live Arcanum deployment behavior, OAuth permissions, representative
  responses, rate-limit headers, and idempotency support

## diffview integration

1. Only one side of the diff works. A diff view has two sides: the "old" version (before the PR) and the "new" version (after the PR, i.e. the head commit). Comments only show up on the "new" side. If you're looking at the "old" side to see what changed, you won't see any comment markers there at all, and you can't leave a new comment on that side either.
2. Fixed: `]C`/`[C` (`:Parley nav review-next/-prev`) now hop between files while browsing in diffview. `]c`/`[c` (within-buffer navigation) already worked unmodified in a diffview buffer — no change needed there. Cross-file jumps used to be impossible from diffview (`review_next`/`review_prev` only knew how to `vim.cmd("edit …")`, which would blow away diffview's split layout and desync the file panel's selection from what's actually open); they now drive diffview's own `set_file_by_path` API when the source buffer is diffview-aliased, then wait for the resulting head-side buffer (attached automatically via this module's existing `DiffviewDiffBufRead` handling) before placing the cursor. Verified end-to-end against real upstream `sindrets/diffview.nvim`: `]C` correctly switches the diff buffer, the cursor, and diffview's own file panel selection (`cur_entry`) all together.
3. Fixed: file-panel badges no longer use text search. They're now placed by walking diffview's own file-panel component tree and matching each badge's file by object identity (`comp.context == file`), covering both `listing_style = "list"` and `"tree"` — the same approach diffview's own `FilePanel:highlight_file()` uses internally. Verified against real upstream `sindrets/diffview.nvim` with two files sharing a basename in different directories (`a/foo.lua`, `b/foo.lua`), which the old text search would have mismatched; each now gets its own correctly placed badge. They still only refresh live on selection/staging under the `diffview-plus.nvim` fork (which fires extra events); under plain upstream `diffview.nvim` they only refresh after a layout change — that's an event-availability gap, not a matching-accuracy one.
4. Fixed and verified: reply/edit/resolve/react/open all work from a diffview buffer now. Two real bugs found and fixed while verifying this (not just "untested"): (a) `review_repository.attach()` was going through the same working-tree-relative `local_mappings` cache regular buffers use, so cursor-based actions in the diffview buffer would target the wrong line — or none — whenever the file being browsed had uncommitted local edits, since that cache diffs against the real file on disk, not the diffview buffer's static head-revision content; fixed by making the diffview-attached buffer use identity mapping structurally (`review_repository._identity_bufnrs`), enforced inside the shared `compute_view` choke point so it survives background refreshes too. (b) The generic `BufEnter`-driven refresh (`services/read.lua`) reclassified and cleared diffview buffers' aliased state the moment the cursor entered them, racing with and usually clobbering diffview_integration.lua's own attach — fixed by skipping diffview buffers entirely in that generic path, since diffview_integration.lua fully owns their lifecycle via its own dedicated events. Verified end-to-end against upstream `sindrets/diffview.nvim` with a real dirty working tree.
5. Verified against `sindrets/diffview.nvim` upstream and the `mistricky/diffview-plus.nvim` fork (module API, real-repo identity/side resolution, and the full attach+render pipeline via a manual smoke test); other forks are unverified.

## Refresh and transport

- Broader GitHub `X-RateLimit-*`, 429, and 403 handling
- Review consistency of setup options across integrations

## UI and quality

- Richer Telescope previews and issue/comment filtering; both discussion pickers
  already exist
- Distinguish remote outdated-comment status from existing local stale-position
  indicators
- Lua language server type warnings in validation
- Broader command/option/highlight documentation coverage and reference validation
- Test isolation for pending callbacks and subscriptions
- Dependency restrictions for source-directory access
