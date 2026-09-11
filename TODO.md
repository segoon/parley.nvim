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

1. Fixed (read-only, Arcanum only): old-side comments now render in diffview's old-side diff buffer. GitHub never captures old-side comment data at all (its provider mapping doesn't read the REST API's LEFT/RIGHT side field) — a separate, larger effort out of scope here. For Arcanum, `providers/arcanum/anchors.lua` previously blanket-rejected every old-side anchor (`unavailable_reason = "Old-side location"`) before it ever reached the same historical/stale-diff check new-side anchors get; it now applies that check symmetrically, so a *current* old-side comment is readable while a genuinely historical one still isn't. Rendering reuses the same identity-mapping machinery as the head side (`review_repository._identity_bufnrs` is now `"new"|"old"` instead of a boolean), matched per-buffer to a specific old-side revision only when some discussion's own anchor says so (`diffview_integration._matches_old_side` — compares against the discussion's stated revision, never a guessed/resolved "base sha", so it can't misattach an unrelated diff). Along the way, found and fixed a second bug: `signs.render` had its own redundant `discussion.projectable()` re-check that still hardcoded `side ~= "old"`, so even a correctly old-side-mapped discussion was silently dropped before rendering — removed it (`mapping.local_line ~= nil`, already side-aware from the caller, was always sufficient). Creating a *new* comment on the old side remains unsupported — both providers' write paths hardcode the new side — so the new-comment keymap stays disabled there. Verified end-to-end against real upstream `sindrets/diffview.nvim`.
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
