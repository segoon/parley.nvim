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

- Richer Telescope previews and issue/comment filtering; both discussion pickers
  already exist
- Distinguish remote outdated-comment status from existing local stale-position
  indicators
- Lua language server type warnings in validation
- Broader command/option/highlight documentation coverage and reference validation
- Test isolation for pending callbacks and subscriptions
- Dependency restrictions for source-directory access
