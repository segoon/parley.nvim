# Remaining work

- :Parley diffview open - must close current herdr sidebar (if any), undo on close

## Review workflows

- Optional Arcanum drafts/publication, suggestions, and old-side/whole-file creation
- Validate live Arcanum deployment behavior, OAuth permissions, representative
  responses, rate-limit headers, and idempotency support

## diffview integration

- Improve file-panel badge refresh under upstream diffview.nvim if it exposes a
  suitable event; diffview-plus.nvim already refreshes on selection and staging.

## Refresh and transport

- Broader GitHub `X-RateLimit-*`, 429, and 403 handling
- Review consistency of setup options across integrations

## UI and quality

- Richer Telescope previews and additional issue/comment filters; unresolved
  filtering is available in both discussion pickers
- Distinguish remote outdated-comment status from existing local stale-position
  indicators
- Lua language server type warnings in validation
- Broader command/option/highlight documentation coverage and reference validation
- Test isolation for pending callbacks and subscriptions
- Dependency restrictions for source-directory access

## Feature research backlog

### Optimistic comment reconciliation

Optimistic posting is implemented for new discussions and replies: pending comments
render immediately, provider results replace them, refresh runs in the background,
and definite failure restores the draft. Add an actionable reconciliation state for
successful provider responses that omit a created comment or cannot confirm it;
currently the pending entry remains visible while background refresh preserves it.

### Additional discussion filters

Add authored-by-me, mentions, stale, and unavailable-location filters. Unresolved
filtering and buffer-local/review-wide unresolved navigation are implemented.

### Apply review suggestions

Recognize provider suggestion blocks, preview their patches, and apply them to the
working buffer with undo support without staging or committing automatically.

### Browser deep links

Open the active review, discussion, or comment in the provider UI and support
copying provider-owned URLs for unsupported workflows.

### CodeDiff integration

Render and navigate Parley discussions in CodeDiff PR and revision buffers,
synchronize its file explorer, and follow its documented lifecycle events.

### Pending review and batch submission

Accumulate supported inline comments and submit them together with an approve,
comment, or request-changes verdict while preserving drafts and explicit
cancellation state.

### Outdated and stale discussion recovery

Distinguish remotely outdated comments from approximate local mappings and offer
the original diff, best current match, or a linked replacement-comment workflow.

### Public discussion integration API

Expose provider-neutral lifecycle events and read-only queries for active review
identity and per-file, per-line, and unresolved discussion counts so other UI
plugins do not depend on Parley internals.
