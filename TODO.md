# Remaining work

- used size: ✅ OK cache_dir exists and is writable: /home/segoon/.cache/nvim/parley

## Review workflows

- Optional Arcanum drafts/publication, suggestions, and old-side/whole-file creation
- Validate live Arcanum deployment behavior, OAuth permissions, representative
  responses, rate-limit headers, and idempotency support

## diffview integration

1. Only one side of the diff works. A diff view has two sides: the "old" version (before the PR) and the "new" version (after the PR, i.e. the head commit). Comments only show up on the "new" side. If you're looking at the "old" side to see what changed, you won't see any comment markers there at all, and you can't leave a new comment on that side either.
2. No jump-to-next/previous-comment navigation while browsing. In a normal file you can press ]c/[c to jump between commented lines. That doesn't have special support for hopping between files inside diffview's file panel yet.
3. The file-panel badges are a bit hacky. They're matched by searching for the filename as plain text in the panel, not through a proper API — if diffview's fork changes how it renders file names, or if two files happen to share a name, the badge could end up on the wrong line.
4. Only replying/editing/resolving via one path. The integration explicitly wires up "add a new comment" from inside diffview. It reuses Parley's normal machinery under the hood, so things like opening the full discussion window to reply/edit/react to an existing comment might work too — but that wasn't specifically tested, so treat it as "probably works, unverified" rather than "confirmed."
5. Only tested against one plugin. It was built and tested against diffview-plus.nvim specifically (a fork of the more common diffview.nvim). It may or may not work with the original diffview.nvim or other forks — nobody's checked.

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
