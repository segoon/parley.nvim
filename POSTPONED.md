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

---

## GitHub provider — GraphQL for thread resolution (Step 9)

`fetch_discussions` currently uses REST
(`GET /repos/{owner}/{repo}/pulls/{number}/comments`) and always returns
`resolved = false` because the REST review-comments endpoint does not expose
thread resolved state.

`resolve` and `unresolve` currently raise:
  "parley.github: resolve/unresolve requires GraphQL (see POSTPONED.md)"

Full implementation requires:

- `fetch_discussions` — replace (or supplement) the REST call with a GraphQL
  query on `pullRequest.reviewThreads { id isResolved ... }`.  Discussion IDs
  would become GraphQL node IDs (e.g. `PRRT_kwDO…`), requiring an internal
  `_thread_root` cache (node_id → root comment db id) for `reply`.
- `resolve` / `unresolve` — `resolveReviewThread` /
  `unresolveReviewThread` GraphQL mutations, taking the thread node ID.
- Statusline unresolved counts are currently only an approximation for GitHub:
  without `isResolved`, Step 17 can only count fetched threads, not truly
  unresolved ones. Replace the approximation once GraphQL thread data lands.

Both can be driven with `gh api graphql -f query='...' -F var=val` — no new
HTTP client work required beyond the existing `_runner` seam.

---

## GitHub provider — multiple PRs for the same branch (Step 9)

`detect_pr` queries with `per_page=1` and silently returns the first result.
When multiple open PRs exist for the same branch (possible in repos that allow
it, or after a base-branch change), the user is given no indication that other
PRs were skipped.

Planned behaviour: fetch up to 2 results (`per_page=2`); if more than one is
returned, surface a warning to the user (e.g. `vim.notify`) listing the PR
numbers and URLs, and return the first (most recently created) one.

Implementation note: the warning should be emitted at the call site (BufEnter
handler / refresh layer), not inside the provider itself, to keep the provider
free of UI concerns.  The provider could instead return all matched PRs (or a
`{pr, warnings}` tuple) and let the caller decide how to present them.
