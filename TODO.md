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
2. No jump-to-next/previous-comment navigation while browsing. In a normal file you can press ]c/[c to jump between commented lines. That doesn't have special support for hopping between files inside diffview's file panel yet.
3. The file-panel badges are a bit hacky. They're matched by searching for the filename as plain text in the panel, not through a proper API — if diffview's fork changes how it renders file names, or if two files happen to share a name, the badge could end up on the wrong line. They also only refresh live on selection/staging under the `diffview-plus.nvim` fork (which fires extra events); under plain upstream `diffview.nvim` they only refresh after a layout change.
4. Only replying/editing/resolving via one path. The integration explicitly wires up "add a new comment" from inside diffview. It reuses Parley's normal machinery under the hood, so things like opening the full discussion window to reply/edit/react to an existing comment might work too — but that wasn't specifically tested, so treat it as "probably works, unverified" rather than "confirmed."
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
