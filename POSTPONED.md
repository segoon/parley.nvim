# Postponed features

## HTTP rate-limit handling (Step 6)

Originally planned as part of the HTTP client wrapper (`lua/parley/http.lua`):

- Track `X-RateLimit-Remaining` and `X-RateLimit-Reset` response headers in
  module-level state (`M._rate_limit`).
- On HTTP 429, or HTTP 403 with `X-RateLimit-Remaining: 0`, compute a sleep
  duration from `Retry-After` or `X-RateLimit-Reset` (Unix epoch), yield via
  `plenary.async.util.sleep`, then retry the request once.
- Injectable `M._sleep` hook for test isolation.

Deferred because it adds complexity before any real GitHub provider exists to
exercise it.  Implement as part of Step 9 (GitHub provider) or as a follow-up
hardening pass once real API calls are being made.
