# Arcanum compatibility

Parley supports Arc-backed Arcanum reviews in regular Neovim buffers and can
attach discussions to matching diffview.nvim buffers. This document records the
provider contracts and limitations that are easy to lose when the API or editor
integration changes. See [README](README.md) for setup, the
[help template](doc/parley.nvim.txt.in) for the full user reference, and
[TODO](TODO.md) for unfinished work.

## Supported workflows

| Workflow | Behavior | Limits |
|---|---|---|
| Discovery | Detect Arc repositories and find an exact remote-branch match across paginated prefix-search results | No remote branch means inactive; malformed or nonprogressing pages fail |
| Authentication | Read supported token sources and bind the Arc login before restoring cached ownership | The selected token must belong to that Arc user |
| Discussions | Preserve nested, orphaned, and cyclic replies, reactions, issue states, and explicit anchor metadata | Unavailable locations remain readable without fabricated positions |
| Inline comments | Create new-side line and range comments using the loaded V2 diff | Requires a clean file, matching HEAD, and an entry in the loaded diff |
| Comment actions | Reply, edit, delete, react, resolve, reopen, and open provider-returned thread or comment links | Only complete open/resolved root issues can transition; missing exact links are reported |
| Review actions | Ship, sticky ship, unship, block merge, and unblock merge | No generic review-message transaction |
| Refresh and cache | Async manual, buffer-entry, post-write, and periodic refresh with account-isolated caches | Polling skips busy or hidden reviews and does not discover new PRs |
| Diffview | Render and act on head-side discussions; render matching old-side Arcanum anchors read-only | New comments are new-side only; automatic `:Parley diffview open` range construction is Git-only |

## Authentication and identity

Credentials are resolved in this order: `ARCANUM_TOKEN`, `ARC_OAUTH_TOKEN`, the
file named by `ARC_TOKEN_PATH`, then `~/.arc/token`. Empty environment values are
skipped. An explicitly selected unreadable or empty token file fails instead of
silently selecting another account.

Review loading uses `user_login` from `arc info --json` for ownership. The selected
token must belong to that user; no `/v2/users/me` call is made. Missing login blocks
session preparation. Credential, host, or login changes reject obsolete responses
and require a refreshed session. Cache identity includes provider, host, repository,
login, and a credential fingerprint; tokens are neither stored in cache keys nor
printed in diagnostics. Identity version 5 invalidates earlier API-viewer caches.

`ya tool arcanum` is required. Every CLI process receives the provider-selected
credential through `ARC_TOKEN` and the explicit HTTPS API URL. Inherited
`ARCANUM_CLI_REVIEW_SYSTEM` is cleared so ordinary comments do not acquire a review
system implicitly. Comment text is passed through stdin, not a shell.

The configured host must be a hostname or bracketed IPv6 address with an optional
port. Schemes, paths, userinfo, queries, fragments, and whitespace are rejected;
all requests use HTTPS.

## API contracts

| Operation | Execution |
|---|---|
| Search | CLI `pr list`, projected cursor pages, then `pr get` for the exact match |
| Active diff | CLI `pr active-diff --fields id,commit_ids(base,head,merge)` |
| Discussions | HTTP `GET /v1/public/review-requests/{id}/comments` to retain full V1 anchors |
| Inline entry | CLI `pr changelist --diff-id … --diff-mode flat_path --ignorews=false --fields path,entry_id` |
| Inline creation | CLI `comment post-diff` with the loaded V2 entry ID |
| Reply/edit/delete | PR-scoped CLI `comment reply/edit/delete`, preserving signed IDs |
| Issue transition | CLI `comment edit --issue-status open|resolved` on the existing root |
| Reactions | PR-scoped CLI `comment add-reaction/remove-reaction`; HTTP removal for codes the CLI rejects |
| Review data | HTTP `GET /v1/plugin/pull-request/{pr_id}/review` |
| Approval | HTTP `PUT .../review/ship?sticky=false|true`; withdrawal uses `DELETE` |
| Merge block | HTTP `PUT .../review/block-merge`; withdrawal uses `DELETE` |

PR-scoped V2 comment operations support general and historical inline comments,
despite the CLI help's narrower “PR-level” wording. Replies inherit the original
parent anchor; existing writes do not resolve a replacement active diff.
The provider retains its internal method/path request descriptions to select a
CLI command or a required HTTP operation before execution. Failed CLI mutations
never fall back to a second HTTP mutation.

The active diff's `head` identifies the pushed source checkout, `base` is the
immutable destination revision, and `merge` is the new side shown in the review.
Sync checks use `head`. Changed-line validation uses `base` → `merge`, never the
moving destination branch. Clean source selections are translated to `merge`
coordinates; changed, deleted, or noncontiguous ranges are rejected. Selections
already displayed in the merge revision are not translated again. Missing
revision metadata/content blocks creation without hiding readable discussions.
Current new-side anchors map from `merge`; old-side anchors retain their explicit
revision and path. Diffview identity mappings require the displayed revision to
match the anchor; a local/source buffer is not the merge side when they differ.

Draft validation and pending transactions use the PR, diff identity, and immutable
revisions. A new diff with the same source head still invalidates a composer.
Pending comments survive refresh only within that snapshot; late completions
cannot alter a replacement review. Optimistic display coordinates stay separate
from remote anchors, and a confirmed root promotes its exact URL to the thread.
A successful callback without usable comment data clears the temporary entry and
refreshes without restoring a retryable draft. Arcanum cache identity version 5
also prevents restoring snapshots from the earlier account and revision models.

Inline creation deliberately uses the loaded diff rather than repeating the
active-diff lookup on submission. Entry lookup failure never falls back to a
general comment. Review actions do recheck the active diff before mutation, but
the server cannot atomically pin that diff; a newly activated diff can still win
the race between the check and the write.

The explicit review-action picker offers ship, sticky ship, unship, block merge,
and unblock merge. Confirmation includes the loaded PR, revision, current viewer
verdict, and sticky semantics. Approval or block withdrawal requires the matching
viewer verdict. Generic review submission with a bundled message is unsupported.

`min_ships_required` is interpreted as the number of remaining approvals. Any
block produces `changes_requested`; otherwise zero produces `approved`, a positive
value produces `pending`, and missing or malformed review data produces `unknown`.
Unknown status disables review actions without hiding discussions.

Parley offers the seven reaction codes accepted by AI comments: `:+1:`, `:heart:`,
`:facepalm:`, `:confused:`, `:goose:`, `:thinking:`, and `:-1:`. Other codes remain
readable and can be removed when owned by the viewer. A conflict requires refresh
and explicit removal rather than automatic replacement. Reaction writes preserve
the add/remove state selected in the picker rather than recomputing a toggle after
the selection is made.

Issue resolution changes only complete root issues between `open` and `resolved`.
Dropped, non-issue, unknown, incomplete, and cyclic discussions remain readable
but cannot transition.

## Transport and write safety

All CLI and HTTP work is asynchronous. Requests sharing a host and token use one
process-local paced queue. A request has one deadline covering queueing, attempts,
and retry waits, including CLI startup. A 429 applies a shared cooldown using
configured backoff; retained HTTP reads can also use `Retry-After` when available. Other Neovim processes and clients are not coordinated.

Default comment and reply creation uses the CLI without automatic retries.
`providers.arcanum.idempotent_write_retries` selects keyed HTTP creation before
sending, with one key per submission reused across retries. Enable it only after
deployment support has been confirmed. Edits, deletions, issue updates, reactions,
and review actions are never retried automatically.

Sparse successful write responses are hydrated by an explicit comment read.
Once acknowledged, failed or cancelled hydration completes successfully without
comment data and the UI refreshes; it never restores a retryable creation draft.
CLI decoding cannot recover malformed server fields already normalized by the CLI;
existing domain validation still applies to the CLI output.

Cancellation cannot undo a request already accepted by the server. Uncertain
writes preserve the draft and instruct the user to inspect the review before
retrying. Session changes invalidate in-flight results.

## CLI reuse decision

The provider uses [`ya tool arcanum`](https://a.yandex-team.ru/arcadia/arcanum/ai-utils/arcanum-go-cli)
where the command preserves its contracts. V1 discussion reads retain richer
historical anchor information than the CLI's V2 representation. Review status and
all five verdicts retain HTTP because equivalent CLI commands are unavailable.
Canonical comment URLs are preserved when supplied by retained reads; neither
inspected V1 nor V2 comment DTO declares them, so their absence is not a proven
CLI regression.

[`ya tool gena-arcanum-cli`](https://a.yandex-team.ru/arcadia/ai/tools/infra-clients/arcanum-client)
is a standalone executable and preserves raw response fields. It offers ship and
sticky ship, but not the full verdict set, reaction commands, or a CLI API-host
override. Its `request-for-changes` is a different action from merge blocking.
Adding it would introduce another adapter without removing the retained HTTP
implementation, so it is not a dependency.

## Validation boundary

The contracts above are covered by mocked HTTP/provider tests, Neovim UI fixtures,
and review against local Arcanum server sources. This does not prove live endpoint
parity, OAuth authorization, rate-limit behavior, or deployed idempotency support.
No live API mutations are part of the automated test suite.

Relevant server contracts include:

- [active diff resource](https://a.yandex-team.ru/arcadia/arcanum/server/arcanum-server-web/src/main/java/ru/yandex/arcanum/web/api/diff/PullRequestActiveDiffResource.java)
- [V2 changelist conversion](https://a.yandex-team.ru/arcadia/arcanum/server/arcanum-server-web/src/main/java/ru/yandex/arcanum/web/v2/diff/DiffSetChangeConverter.kt)
- [public issue update handler](https://a.yandex-team.ru/arcadia/arcanum/server/arcanum-server-web/src/main/java/ru/yandex/arcanum/web/api/comment/PublicCommentForReviewRequestsResource.java)
- [PR reaction resource](https://a.yandex-team.ru/arcadia/arcanum/server/arcanum-server-web/src/main/java/ru/yandex/arcanum/web/plugin/api/PluginPullRequestReactionResource.kt)
- [review resource](https://a.yandex-team.ru/arcadia/arcanum/server/arcanum-server-web/src/main/java/ru/yandex/arcanum/web/plugin/api/PluginReviewResource.kt)

Remaining Arcanum work is limited to optional drafts/publication, suggestions,
additional creation anchors, and representative live-deployment validation. It is
tracked in [TODO](TODO.md).
