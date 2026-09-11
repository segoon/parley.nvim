# GitHub compatibility

Parley supports GitHub pull-request discussions through Git and the `gh` CLI. This
document records provider contracts and limitations. See [README](README.md) for
setup, the [help template](doc/parley.nvim.txt.in) for the full user reference,
and [TODO](TODO.md) for unfinished work.

## Supported workflows

| Workflow | Behavior | Limits |
|---|---|---|
| Discovery | Detect a Git working copy, parse its `origin`, and find an open PR for the current branch | Automatic provider selection currently accepts `github.com` remotes only |
| Authentication | Resolve host-appropriate environment tokens or `gh`'s `hosts.yml` token | Interactive login, SSO, and keyring behavior remain owned by `gh` |
| Discussions | Read paginated REST review comments and group roots with replies | GraphQL resolution metadata is overlaid separately |
| Inline comments | Create new-side line and range comments | Requires a clean file, matching HEAD, and changed lines in the loaded review |
| Comment actions | Reply, edit, delete, react, resolve, reopen, and open canonical thread links | Resolution requires a GraphQL thread ID from a successful discussion fetch |
| Review submission | Approve, request changes, or comment with a body | The explicit review-action picker is not implemented for GitHub |
| Refresh and cache | Use shared async refresh and account-isolated review caches | Missing stable local credential identity disables persistent caching |
| Diffview | Construct the Git base...head range, render head-side discussions, create comments, and navigate files | Existing mapping does not retain GitHub old-side metadata |

## Repository, authentication, and identity

The Git detector uses `git rev-parse`, the current non-detached branch, and the
`origin` remote. SSH and HTTP(S) GitHub URLs are parsed, but automatic built-in
provider selection currently accepts only the `github.com` host. The provider's
explicit constructor supports a configured GitHub Enterprise Server host and API
base; that path is not selected automatically from arbitrary enterprise remotes.

For `github.com` and `*.ghe.com`, credentials are resolved from `GH_TOKEN`, then
`GITHUB_TOKEN`. Other enterprise hosts use `GH_ENTERPRISE_TOKEN`, then
`GITHUB_ENTERPRISE_TOKEN`. If no environment token is present, Parley reads the
matching `oauth_token` from `gh`'s `hosts.yml`, following `GH_CONFIG_DIR`,
`XDG_CONFIG_HOME`, and `HOME` precedence.

Cache identity includes the host, API base, repository, token, and local viewer
context through a one-way fingerprint. Credentials are not stored in cache keys.
If a stable local credential cannot be established, persistent caching is disabled
for that provider instance.

## API contracts

| Operation | Contract |
|---|---|
| PR discovery | `GET /repos/{owner}/{repo}/pulls?head={owner}:{branch}&state=open` |
| Review status | `GET /repos/{owner}/{repo}/pulls/{number}/reviews` |
| Discussions | `GET --paginate /repos/{owner}/{repo}/pulls/{number}/comments` |
| Thread state | GraphQL `reviewThreads`, paginated and correlated by root comment database ID |
| Inline creation | `POST /repos/{owner}/{repo}/pulls/{number}/comments` |
| Reply | `POST /repos/{owner}/{repo}/pulls/{number}/comments` with `in_reply_to` |
| Edit/delete | `PATCH` or `DELETE /repos/{owner}/{repo}/pulls/comments/{comment_id}` |
| Reaction | `POST` or `DELETE /repos/{owner}/{repo}/pulls/comments/{comment_id}/reactions` |
| Resolution | GraphQL `resolveReviewThread` or `unresolveReviewThread` |
| Review submission | `POST /repos/{owner}/{repo}/pulls/{number}/reviews` |

Discussion IDs use the root REST review-comment database ID. A separate GraphQL
query maps that ID to the review-thread node ID and overlays its resolved state.
If the GraphQL read fails, REST discussions remain readable but no node ID is
available for resolution writes until a later successful refresh.

New comments and replies use the loaded review head. Shared write validation
requires local HEAD to match it, rejects dirty or unsaved files, and restricts new
comments to changed new-side lines. GitHub's current REST mapping falls back to
`original_line` when necessary but does not retain the API's left/right side as
old-side anchor metadata.

Review status is derived from REST review verdicts. Review submission accepts
`approve`, `request_changes`, or `comment`, mapped to GitHub's corresponding review
events, and requires a body through the shared workflow.

The reaction picker exposes GitHub's supported review-comment reactions: `+1`,
`-1`, `laugh`, `confused`, `heart`, `hooray`, `rocket`, and `eyes`.

## Transport and failure handling

API operations run through `gh api` subprocesses. Coroutine and callback entry
points apply the configured timeout and exponential backoff to recognized transient
CLI/network failures. Non-transient failures and invalid JSON fail immediately.
Cancellable callback writes terminate the active subprocess or pending retry and
complete at most once.

GitHub transport does not currently implement explicit `X-RateLimit-*`, HTTP 429,
or HTTP 403 scheduling. Broader handling is tracked in [TODO](TODO.md); behavior
provided internally by `gh` remains outside Parley's guarantees.

## Validation boundary

The contracts above are covered by mocked CLI/provider tests and Neovim fixtures.
They do not prove live GitHub or GitHub Enterprise authorization, SSO behavior,
rate-limit handling, or API-version compatibility. No live API mutations are part
of the automated test suite.
