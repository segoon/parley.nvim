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
| Authentication | Read supported token sources and verify the API viewer before restoring cached ownership | The local Arc login is diagnostic only |
| Discussions | Preserve nested, orphaned, and cyclic replies, reactions, issue states, and explicit anchor metadata | Unavailable locations remain readable without fabricated positions |
| Inline comments | Create new-side line and range comments using the loaded V2 diff | Requires a clean file, matching HEAD, and an entry in the loaded diff |
| Comment actions | Reply, edit, delete, react, resolve, and reopen | Only complete open/resolved root issues can transition; ownership and permissions still apply |
| Review actions | Ship, sticky ship, unship, block merge, and unblock merge | No generic review-message transaction |
| Refresh and cache | Async manual, buffer-entry, post-write, and periodic refresh with account-isolated caches | Polling skips busy or hidden reviews and does not discover new PRs |
| Diffview | Render and act on head-side discussions; render matching old-side Arcanum anchors read-only | New comments are new-side only; automatic `:Parley diffview open` range construction is Git-only |

## Authentication and identity

Credentials are resolved in this order: `ARCANUM_TOKEN`, `ARC_OAUTH_TOKEN`, the
file named by `ARC_TOKEN_PATH`, then `~/.arc/token`. Empty environment values are
skipped. An explicitly selected unreadable or empty token file fails instead of
silently selecting another account.

Review loading verifies `/v2/users/me?fields=name` before publishing cache
identity. Only the verified API login determines comment ownership. Credential or
host changes reject obsolete responses and require a refreshed session. Cache
identity includes provider, host, repository, and an account fingerprint; tokens
are neither stored in cache keys nor printed in diagnostics.

The configured host must be a hostname or bracketed IPv6 address with an optional
port. Schemes, paths, userinfo, queries, fragments, and whitespace are rejected;
all requests use HTTPS.

## API contracts

| Operation | Contract |
|---|---|
| Search | `POST /v1/pull-requests/cursor`, followed by exact branch comparison |
| Active diff | `GET /v1/pull-requests/{id}/active-diff?fields=id,commit_ids(head)` |
| Discussions | `GET /v1/public/review-requests/{id}/comments` |
| Inline entry | `GET /v2/public/diff/{diff_id}/changelist` |
| Inline creation | `POST /v2/public/diff/{diff_id}/comment` with the V2 entry ID |
| Issue transition | `PATCH /v1/public/review-requests-comments/{root_id}` |
| Reaction state | `PUT` or `DELETE /v1/plugin/pull-request/{pr_id}/comment/{comment_id}/reaction/{code}` |
| Review data | `GET /v1/plugin/pull-request/{pr_id}/review` |
| Approval | `PUT .../review/ship?sticky=false|true`; withdrawal uses `DELETE` |
| Merge block | `PUT .../review/block-merge`; withdrawal uses `DELETE` |

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

All HTTP work is asynchronous. Requests sharing a host and token use one
process-local paced queue. A request has one deadline covering queueing, attempts,
and retry waits; 429 responses apply a shared cooldown using `Retry-After` when
available. Other Neovim processes and clients are not coordinated.

Comment and reply creation use one idempotency key per operation. Automatic create
retries remain disabled unless `providers.arcanum.idempotent_write_retries` is
enabled after deployment support has been confirmed. Edits, deletions, issue
updates, reactions, and review actions are not retried automatically.

Cancellation cannot undo a request already accepted by the server. Uncertain
writes preserve the draft and instruct the user to inspect the review before
retrying. Session changes invalidate in-flight results.

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
