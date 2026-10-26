# GitHub compatibility

Parley supports GitHub pull-request discussions through Git and the `gh` CLI (version 2.48 or newer). This
document records provider contracts and limitations. See [README](README.md) for
setup, the [help template](doc/parley.nvim.txt.in) for the full user reference,
and [TODO](TODO.md) for unfinished work.

## Supported workflows

| Workflow | Behavior | Limits |
|---|---|---|
| Discovery | Detect a Git working copy, parse its `origin`, and find an open PR for the current branch | Automatic provider selection currently accepts `github.com` remotes only |
| Authentication | Delegate host-specific credential selection to `gh auth token` | Environment, config, keyring, and token refresh behavior remain owned by `gh` |
| Discussions | Read paginated REST review comments and group roots with replies | GraphQL resolution metadata is overlaid separately |
| Inline comments | Create new-side line and range comments | Requires a clean file, matching HEAD, and changed lines in the loaded review |
| Comment actions | Reply, edit, delete, react, resolve, reopen, and open canonical thread or comment links | Resolution requires a GraphQL thread ID from a successful discussion fetch |
| Review submission | Approve, request changes, or comment with a body | The explicit review-action picker is not implemented for GitHub |
| Refresh and cache | Use shared async refresh and account-isolated review caches | Missing stable local credential identity disables persistent caching |
| Diffview | Construct the Git base...head range, render head-side discussions, create comments, and navigate files | Existing mapping does not retain GitHub old-side metadata |

## Repository, authentication, and identity

The Git detector uses `git rev-parse`, the current non-detached branch, and the
`origin` remote. SSH and HTTP(S) GitHub URLs are parsed, but automatic built-in
provider selection currently accepts only the `github.com` host. The provider's
explicit constructor supports a configured GitHub Enterprise Server host and API
base; that path is not selected automatically from arbitrary enterprise remotes.
Every request explicitly selects the configured host, overriding `GH_HOST` and CLI
defaults; `gh pr view` receives `--repo HOST/OWNER/REPO`. A custom API base is used for REST paths; GraphQL uses
the same base with a trailing `/v3` replaced by `/graphql` (or `/graphql` appended
when there is no `/v3` suffix).

Parley resolves credentials asynchronously with `gh auth token --hostname <host>`.
The CLI owns environment precedence, active-account selection, configuration paths,
and secure storage. Parley does not parse `hosts.yml`. Run `gh auth login` to set
up authentication. Credential lookup has a timeout and its output is never logged.

Preparation captures the selected token. API subprocesses receive that token via
their environment, and credential checks before and after each operation reject
obsolete results. A changed or unavailable credential invalidates the session;
refresh the review before continuing. An interrupted mutation may still have been
sent and must be checked before retrying.

Cache identity includes host, API base, repository, and a one-way token fingerprint.
The getter performs no I/O. Credentials are not stored in cache keys. If a stable
credential cannot be established during preparation, persistent caching is disabled
for that provider instance. The versioned fingerprint causes a cold refresh of
earlier cached GitHub reviews, removing config-derived ownership and individual
review verdicts.

Viewer identity comes only from `GET /user` using the prepared credential, and is
cached for that session. Local gh account configuration is not used to infer
ownership. Failed viewer lookup leaves comment ownership unknown and prevents
reaction toggles from guessing whether to add or remove a reaction.

Health checks resolve credentials through `gh` without refreshing tokens, including
secure-store credentials. Older CLI versions that do not refresh tokens fall back
to their original token command. Health checks do not validate server authorization.

## API contracts

| Operation | Contract |
|---|---|
| PR discovery and metadata | `gh pr view <branch> --json ... --repo HOST/OWNER/REPO`; only open results are accepted |
| Review status | GitHub's aggregate `reviewDecision`, included in PR metadata |
| Viewer identity | `GET /user` using the prepared credential |
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
`original_line` and `original_start_line` together when necessary. Current
multiline comments preserve `start_line` through `line`. Whole-file and unavailable
locations remain readable without fabricated line numbers. The mapping does not
yet retain the API's left/right side as old-side anchor metadata.

Custom API URLs and numeric branch names retain an explicit open-branch REST
lookup followed by a GraphQL metadata query. The CLI cannot select arbitrary API
URLs and interprets numeric selectors as PR numbers. A missing branch result or a
closed/merged PR leaves Parley inactive; authentication and request failures are
reported rather than treated as absence.

Review status reflects GitHub's aggregate decision: `APPROVED` maps to `approved`,
`CHANGES_REQUESTED` to `changes_requested`, and `REVIEW_REQUIRED` to `pending`.
Missing, null, empty, or unrecognized decisions map to `unknown` without blocking
discussion loading. Individual `COMMENTED` and `DISMISSED` review events no longer
override a PR's aggregate status. Failure of the whole metadata request fails the
refresh. Review submission accepts
`approve`, `request_changes`, or `comment`, mapped to GitHub's corresponding review
events, and requires a body through the shared workflow.

The reaction picker exposes GitHub's supported review-comment reactions: `+1`,
`-1`, `laugh`, `confused`, `heart`, `hooray`, `rocket`, and `eyes`.

## Transport and failure handling

Network operations run through `gh api` or `gh pr view` subprocesses. Coroutine and callback entry
points share one request lifecycle with timeout, retry, cancellation, decoding,
and at-most-once completion.

REST lists (comments and reactions) use `--paginate --slurp`; Parley
flattens the resulting page arrays. Standard GraphQL thread queries use the same
flags and `$endCursor`. A failed later page does not publish partial metadata.
Custom API bases retain explicit cursor traversal because `gh` only recognizes
its literal `graphql` endpoint for GraphQL pagination. Absolute GraphQL requests
encode parameters under `variables`. Failed thread refreshes clear cached thread
IDs before resolution writes can use them.

Local line mapping uses `vim.diff(..., { result_type = "indices" })` directly.
Git's review-range patch parsing remains responsible for changed-line write
validation; local buffer diffs do not redefine which lines GitHub accepts.

Read requests retry recognized transient CLI/network failures with exponential backoff; mutations are never automatically
replayed. Ambiguous write failures, malformed write responses, and cancellation
after sending report uncertainty and ask the user to check the review before
retrying. Cancellable callback writes terminate the active subprocess and complete
at most once, without waiting for its exit callback.

GitHub transport does not currently implement explicit `X-RateLimit-*`, HTTP 429,
or HTTP 403 scheduling. Broader handling is tracked in [TODO](TODO.md); behavior
provided internally by `gh` remains outside Parley's guarantees.

## Validation boundary

The contracts above are covered by mocked CLI/provider tests and Neovim fixtures.
They do not prove live GitHub or GitHub Enterprise authorization, SSO behavior,
rate-limit handling, or API-version compatibility. No live API mutations are part
of the automated test suite.
