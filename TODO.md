# TODO

features:
- :Telescope discussions|issues|comments? vcs_issues? - preview
- multiple discussions of the same line
- resolve/unresolve thread, unresolved count (GraphQL)

# Remaining work

## Review workflows

- Diffview integration: revision/side mapping, rendering, navigation, and composition
  (context detection alone is implemented)
- GitHub thread resolution/reopening and resolved state through GraphQL
- Optional Arcanum drafts/publication, suggestions, and old-side/whole-file creation
- Validate live Arcanum deployment behavior, OAuth permissions, representative
  responses, rate-limit headers, and idempotency support

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
