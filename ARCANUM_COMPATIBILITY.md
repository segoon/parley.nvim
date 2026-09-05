# Arcanum compatibility

Current implementation as of 2026-09-05. Compatibility backlog items **1–8 are
implemented**, including documentation reconciliation. Parley supports Arc-backed
reviews in regular Neovim file buffers. Validation uses local server source,
mocked HTTP/providers, and real Neovim UI fixtures; live deployment compatibility
and token authorization remain unverified.

## Current support

| Workflow | Implemented behavior | Limits |
|---|---|---|
| Repository and review discovery | Arc detection; paginated prefix search with exact remote-branch matching | No remote branch means inactive; malformed/nonprogressing pages fail |
| Authentication | Alternate Arc token sources and verified API viewer before cache restoration | Local Arc login is diagnostic only; verification failure stops loading |
| Configured host and health | Consistent HTTPS host for reads/writes/cache; local tools and credential diagnostics | Health does not make API requests or validate server access |
| Local mapping | Git/Arc adapters compare review-head content with working files and unsaved buffers | Missing content yields stale approximations; mappings remain checkout-specific |
| Discussion reading | Full parent graphs, explicit anchor metadata, distinct issue states | General, old-side, historical, and unavailable threads remain accessible without fabricated positions |
| Navigation and selection | Built-in discussion list, current-line picker, Telescope, and quickfix | Navigation needs usable positions; quickfix omits general threads and marks unavailable file positions invalid |
| New inline comments | V2 changelist and creation schemas; line/range validation | Loaded new-side diff only; clean file and matching local HEAD required; no silent general-comment fallback |
| Replies, edits, deletion | Existing-comment actions using verified ownership | Delete requires confirmation; account and server permissions still apply |
| Issue resolution | Complete root issues transition open ↔ resolved | Dropped, non-issue, unknown, incomplete, and cyclic threads cannot transition |
| Reactions | Thumbs up/down and heart; removal of other viewer-owned codes | AI comments permit one viewer reaction; replacement requires explicit removal |
| Review actions | Ship, sticky ship, unship, block merge, unblock merge | Confirmation and active-diff recheck; no generic review message transaction |
| Review status | Actual reviewer verdicts and remaining approval requirements | Failed/malformed reads yield unknown and disable review actions, while discussions remain readable |
| Refresh and caching | Async buffer-entry/manual/write and periodic visible-review refresh; versioned account-isolated caches | Polling pauses while unfocused, skips busy reviews, and does not discover new PRs |
| Diffview | Context detection exists | Review services currently support regular buffers only |

See [README](README.md) for setup and [the help template](doc/parley.nvim.txt.in)
for commands, provider capabilities, and configuration. [PROJECT](PROJECT.md)
separates implemented workflows from future goals; [TODO](TODO.md) tracks follow-up work.

## Authentication and identity

Credentials are resolved in this order: `ARCANUM_TOKEN`, `ARC_OAUTH_TOKEN`, the file
named by `ARC_TOKEN_PATH`, then `~/.arc/token`. Values are trimmed and empty
environment values are skipped. An explicitly selected unreadable or empty token
file fails instead of switching accounts through a fallback.

Review loading calls `/v2/users/me?fields=name` before publishing cache identity.
Only the verified API login determines ownership. Changed credentials reject
obsolete responses and require a refreshed session. Direct provider mutations
require that verified session.

The configured host accepts a hostname or bracketed IPv6 address with optional
port, without a URL scheme, path, userinfo, query, fragment, or whitespace.
Requests use HTTPS. Cache identity binds provider, host, repository, and account
fingerprint; tokens are not stored in keys or printed in diagnostics. The
`reviews-v3` namespace and Arcanum's versioned ownership/review fingerprint prevent
reuse of older lossy discussion or inferred-approval data. Local checkout mappings
are separate from shared remote data.

## Remote contracts and action semantics

| Operation | Contract |
|---|---|
| Search | `POST /v1/pull-requests/cursor`, using numeric offset and `has_next`; fetch candidate details and require an exact branch |
| Active diff | `GET /v1/pull-requests/{id}/active-diff?fields=id,commit_ids(head)` |
| Discussions | `GET /v1/public/review-requests/{id}/comments`; preserve string comment IDs, parents, reaction codes, and anchor metadata |
| Inline entry lookup | `GET /v2/public/diff/{diff_id}/changelist`; use its V2 serialized entry ID with V2 creation |
| Issue transition | `PATCH /v1/public/review-requests-comments/{root_id}` with `issue_status` set to `open` or `resolved` |
| Reaction state | `PUT` or `DELETE /v1/plugin/pull-request/{pr_id}/comment/{comment_id}/reaction/{code}`; encode the code as one path segment |
| Review data | `GET /v1/plugin/pull-request/{pr_id}/review?fields=reviewers(user(name),action),min_ships_required` |
| Approval | `PUT .../review/ship?sticky=false` for active-diff approval; `sticky=true` for PR-level approval including future diffs |
| Approval withdrawal | `DELETE .../review/ship`; requires the viewer's corresponding approval in loaded review data |
| Merge block | `PUT .../review/block-merge`; withdrawal uses `DELETE` and requires the viewer's current block |

Inline comments use the loaded diff and do not repeat the active-diff lookup on
submission. Entry lookup failure preserves the draft. A numeric diff ID is used
as the active diff XID, never a GSID; V2 entry IDs are not sent to the V1 creation
schema. Sparse API fields needed for identity, revision, or mapping are requested
explicitly.

The reaction PR route supports comments across inline, general, and historical
locations without substituting the current diff identity. The common codes are
`:+1:`, `:-1:`, and `:heart:`. Other codes remain readable and viewer-owned ones
are removable. Public comment DTOs do not reliably identify AI comments; HTTP 409
triggers a refresh and asks for explicit removal rather than replacing another
reaction automatically. A known conflict is distinct from an uncertain write.

The review field `min_ships_required` contains the server's **remaining approvals**
(`minimumShipsLeft`), not its configured total. Any block produces
`changes_requested`; otherwise zero remaining approvals produces `approved`, and
an outstanding requirement produces `pending`. Missing or malformed data produces
`unknown`. Merge/discard status is not used to infer approval.

`:Parley review actions` confirms the loaded PR, revision, viewer verdict, and
sticky semantics, then rechecks the active diff immediately before the write.
The server API cannot atomically pin an expected diff, so a new diff activated
between the recheck and mutation can still receive the action. Arcanum's generic
`submit_review(event, body)` remains unsupported; no review message is discarded.

Reactions and withdrawals require `GENERIC_WRITE`; ship/sticky ship and block
additions require `REVIEW_REQUEST_SHIP`. Review reads require `GENERIC_READ`.
Capability metadata describes implementation, not authorization. Ordinary tokens
cannot use the admin-only authorities endpoint for scope preflight. HTTP 401/403
responses are explained without exposing server error content; account/review
permissions remain authoritative.

## Transport and editor failure handling

Arcanum uses asynchronous curl through Plenary. Callback and coroutine entry
points share a transport lifecycle with exactly-once completion, cancellation,
process termination, pacing, and deadlines. Each request has a default 10-second
budget covering queueing, attempts, and retry waits; prerequisite and mutation
requests have separate budgets.

Request starts sharing a host/token are spaced one second apart by default.
The per-process scheduler respects shared 429 cooldowns and Retry-After seconds
or HTTP dates. Other Neovim processes and clients are not coordinated.

Comment/reply creates carry a per-operation idempotency key. Automatic retries
remain disabled unless `idempotent_write_retries` explicitly confirms deployment
support. Edits, deletions, issue PATCHes, reactions, and review-action mutations
are not automatically retried. Keys are not persisted across manual resubmissions
or Neovim restarts. Local server support is not proof of deployment parity.

Picker actions revalidate review/account context; reaction writes use the desired
state captured at selection. Successful, conflicting, cancelled, and uncertain
action refreshes preserve selected discussions and composer text. Failed creation
or response mapping leaves drafts available. Cancelling a process cannot roll back
an accepted write: check remote state before retrying an uncertain outcome.

## Validation and evidence

The current implementation and documentation passed **1,073 tests, 0 failures/errors**,
plus `make format`, `make format-check`, and `make lint` (192 Lua files, zero lint
warnings/errors). Generated help was checked in a temporary copy, including tag
generation and reference resolution; the repository's generated help file was not
edited. Changed Lua files remain within 600 lines.

Coverage includes realistic request bodies and sparse DTOs, configured-host flows,
pagination, verified ownership and cache isolation, nested/orphan/cyclic threads,
side/revision anchors, issue states, code encoding, sticky and withdrawal semantics,
unknown verdicts, stale contexts, permission failures, no mutation retries,
queue/deadline/cancellation races, duplicate callbacks, and real float/draft
preservation. These are mocked integration and unit tests, not live API validation.

Contracts were checked against the local Arcadia server sources:

- [Active diff resource](https://a.yandex-team.ru/arcadia/arcanum/server/arcanum-server-web/src/main/java/ru/yandex/arcanum/web/api/diff/PullRequestActiveDiffResource.java)
  and [DiffDto](https://a.yandex-team.ru/arcadia/arcanum/server/arcanum-server-web/src/main/java/ru/yandex/arcanum/web/api/model/DiffDto.java)
  establish opt-in identity/revision fields.
- [DiffSetXid](https://a.yandex-team.ru/arcadia/arcanum/server/arcanum-diff-set/src/main/java/ru/yandex/arcanum/diffset/DiffSetXid.java)
  and [V2 changelist conversion](https://a.yandex-team.ru/arcadia/arcanum/server/arcanum-server-web/src/main/java/ru/yandex/arcanum/web/v2/diff/DiffSetChangeConverter.kt)
  establish numeric diff identifiers and V2 entry shapes.
- [Public issue update handler](https://a.yandex-team.ru/arcadia/arcanum/server/arcanum-server-web/src/main/java/ru/yandex/arcanum/web/api/comment/PublicCommentForReviewRequestsResource.java)
  defines issue-status PATCH writes.
- [PR reaction resource](https://a.yandex-team.ru/arcadia/arcanum/server/arcanum-server-web/src/main/java/ru/yandex/arcanum/web/plugin/api/PluginPullRequestReactionResource.kt)
  defines reaction routes, permissions, and AI restrictions.
- [Review resource](https://a.yandex-team.ru/arcadia/arcanum/server/arcanum-server-web/src/main/java/ru/yandex/arcanum/web/plugin/api/PluginReviewResource.kt)
  defines ordinary/sticky actions, remaining approval counts, and active-diff selection.

The inspected Arc CLI was version `20036045 (2026-06-24)`. Live endpoint deployment,
production response fixtures, OAuth access, rate-limit behavior, and deployment
idempotency support still need verification. No live API mutations were used for
this compatibility work.

## Follow-up work

The eight-item compatibility backlog is complete. Next work is explicitly separate:

- Design and implement Diffview integration.
- Add optional Arcanum drafts/publication, suggestions, and additional creation anchors.
- Validate deployed API behavior and permissions with representative environments.

Periodic refresh is implemented as a follow-up: `refresh_interval` defaults to
300 seconds, with 0 disabling polling. Only active reviews visible in the current
tab are polled, once per shared review, including discussion/composer source files.
Rounds are sequential and quiet, skip busy reads/writes, and pause on focus loss.
Setup/focus regain and completed rounds wait a full interval. Timer replacement,
shutdown, and generation guards prevent obsolete callbacks from restarting work.

Implementation difficulties: early returns in the read service did not complete
callbacks, which could leave a polling round stuck. Completion is now exactly once,
including preparation failures. Background refresh also needs to distinguish a
changed review from a custom provider's renewed temporary identity; checkout and
branch checks preserve uncached live reviews without polling a newly selected branch.
Regression tests cover these cases and real discussion-draft preservation.

### Where to report

If you're sure the reported difficulties above are related to techplatform (e.g. userver, c35),
please report to [aisuite](https://nda.ya.ru/t/EcUMOwSH7eudWX).
