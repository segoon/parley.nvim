# Arcanum compatibility research

Research date: 2026-09-04. Scope: Parley's current working-tree implementation,
its tests and plans, installed Arc CLI help, and Arcanum server/MCP source in the
local Arcadia checkout. Server-source findings describe that checkout; deployment
parity and authenticated end-to-end behavior were not tested. No Git commands or
remote comment/review mutations were executed.

## Implementation update

The shared-workflow fix is implemented: explicit Git/Arc adapters, revision-to-buffer
mapping (including unsaved edits), separate checkout projections, visibly stale
fallbacks, and clean-file/revision validation both before drafting and submission.
Active-diff requests now include `commit_ids(head)`.

Inline API-contract backlog item **2 is also implemented**: numeric diff XIDs,
V2 changelist and creation schemas, explicit creation response fields, one shared
callback/coroutine operation, diff-scoped entry caching, and fail-closed inline
validation. Lookup failures preserve drafts instead of posting general comments.
Submission deliberately uses the loaded review without re-fetching the active diff.

Transport backlog item **3 is implemented**: shared callback/coroutine HTTP
lifecycle, error callbacks, process termination on cancellation, a whole-request
deadline, and per-host/credential pacing with shared 429 cooldowns. Comment/reply
operations always carry a per-operation idempotency key; automatic write retries
remain disabled unless `idempotent_write_retries` explicitly confirms deployment
support. Replies and inline comments preserve uncertain outcomes through mapping
failures and cancellation into the composer.

Validation for item 3 (2026-09-05): **960 tests passed, 0 failures/errors**.
`make format`, `make format-check`, and `make lint` passed (147 Lua files,
0 lint warnings/errors). Deterministic tests cover queue and attempt deadlines,
nonzero curl exits, process cancellation, late handles/callbacks, Retry-After
seconds and GMT dates, scope isolation, retry exhaustion, lost responses with
stable keys/payloads, opt-in mutation retries, and composer draft preservation.
The real local key generator also passed a smoke check. Tests used mocked HTTP;
no live API writes or Git commands were used. README and the help template were
updated; generated help was not edited.

Discussion backlog item **4 is implemented**: full parent graphs, deterministic
ordering, explicit side/path/revision anchors, and distinct issue states. General,
whole-file, old-side, historical, and unavailable threads remain accessible via
`:Parley discussion list` and Telescope without fabricated buffer locations.
Selected threads refresh in place, retaining composer text. Disk review caches
use a new namespace to prevent reuse of earlier lossy discussion data.

Validation for item 4 (2026-09-05): **973 tests passed, 0 failures/errors**.
`make format`, `make format-check`, and `make lint` passed (154 Lua files,
0 lint warnings/errors). Tests cover thread graphs, anchor metadata, issue states,
unlocated selection, real float refresh with draft preservation, and quickfix
location safety. Validation used mocked providers; live API behavior is unverified.

Issue-action backlog item **5 is implemented**: Arcanum root issue PATCH writes,
resolve/reopen commands, and explicit provider capability metadata. Only complete
open/resolved threads may transition. Shared guards prevent unsupported composers,
reaction choices, deletion confirmation, and submissions; legacy custom providers
retain existing actions while resolution requires explicit support. Selected
threads and drafts survive issue refreshes. PATCH mutations are not retried.

Validation for item 5 (2026-09-05): **1,000 tests passed, 0 failures/errors**.
`make format`, `make format-check`, and `make lint` passed (170 Lua files,
0 lint warnings/errors). Tests cover capability declarations and legacy fallback,
blocked interaction/submission, command selection and stale contexts, exact PATCH
bodies, callback/coroutine parity, credentials and permission failures, no automatic
PATCH retries, cancellation, uncertain outcomes, and real float/draft preservation.
Command and support documentation are checked against their shared declarations.
No live API mutations were used; generated help remains untouched.

Implementation difficulty: invalid root-ID validation inside the coroutine adapter
caused Plenary to terminate one test process without reporting failed assertions.
Moving validation before the adapter fixed the timeout; process exit status and
signals were checked alongside test totals. The regression remains covered.

Detection/authentication backlog item **6 is implemented**: paginated exact-branch
search, alternate Arc credential sources, verified API ownership before cache
restoration, credential-bound requests and versioned ownership cache identity,
validated configured hosts, and local-only diagnostics. Explicit unreadable token
paths and failed viewer verification stop loading rather than changing accounts.
The local Arc login is diagnostic metadata and never supplies comment ownership.

Validation for item 6 (2026-09-05): **1,024 tests passed, 0 failures/errors**.
`make format`, `make format-check`, and `make lint` passed (180 Lua files,
0 lint warnings/errors). Tests cover paginated exact matches, duplicate and malformed
pages, absent upstream, credential precedence, invalid explicit paths, verified
ownership, viewer failure, changed credentials and obsolete responses, cache isolation,
preparation failure before cache restoration, configured-host read/write workflows,
and local diagnostics. HTTP was mocked; no live API mutations were performed.

Implementation difficulty: the endpoint named cursor uses numeric offset/has_next,
and the old help incorrectly described local-login detection and ownership. Exact
server DTOs and the current-user handler resolved those discrepancies; regression
tests cover both pagination and verified ownership. Generated help was not edited.

Reaction/review backlog item **7 is implemented**: common Arcanum reaction codes,
removal of other viewer-owned codes, and the explicit `:Parley review actions`
picker. Ship, sticky ship, unship, block merge, and unblock merge preserve their
server meanings. Confirmation shows the loaded PR/revision and viewer verdict;
a cancellable active-diff recheck precedes each mutation. The API cannot atomically
pin the expected diff, so the remaining recheck/write race is documented.

Review status comes from plugin reviewer data and remaining approval requirements;
failed or malformed reads yield `unknown` without hiding discussions. Review actions
remain disabled until that data is available. Arcanum ownership cache identity is
versioned again to exclude old inferred approval data. Reactions use the PR comment
route for inline, general, and historical comments, and send the desired state
captured in the picker. AI conflicts refresh without automatically removing another
reaction. Known conflicts are distinct from uncertain write outcomes.

Validation for item 7 (2026-09-05): **1,049 tests passed, 0 failures/errors**.
`make format`, `make format-check`, and `make lint` passed (187 Lua files,
0 lint warnings/errors). Changed Lua files remain within 600 lines. Tests cover
exact routes and sticky flags, remaining-approval normalization, unknown status,
withdrawal eligibility, confirmation cancellation, stale diffs/accounts/comments,
encoded reaction codes, desired-state preservation, scope failures, no mutation
retries, cancellation in either stage, duplicate/late callbacks, and real float/draft
preservation after successful, conflicting, and uncertain results. HTTP was mocked;
no live API mutations were performed. Generated help remains untouched.

Implementation difficulties: the wire field `min_ships_required` actually contains
`minimumShipsLeft`, and public comment DTOs do not reliably identify AI comments.
The implementation validates the server count and handles AI conflicts by HTTP
status. Transport now retains that status even when a structured API error body
replaces its message. Regression tests prevent accidental classification by message
text. Ordinary credentials cannot call the admin-only authorities endpoint:
GENERIC_WRITE / REVIEW_REQUEST_SHIP requirements are documented and 401/403 errors
are explained safely, while authorization remains server-side.

The findings below describe the research baseline. The next unfinished item is
**8: reconcile the remaining documentation backlog**; live deployment compatibility
remains unverified. Queue coordination is process-local, and keys are not persisted
across manual resubmissions or Neovim restarts.

Validation for item 2 (2026-09-05): **927 tests passed, 0 failures/errors**.
`make format`, `make format-check`, and `make lint` passed (141 Lua files,
0 lint warnings/errors). Tests include V2 range/single-line bodies, coroutine and
callback entry points, sparse metadata, null response fields, diff-scoped caches,
cancellation races, and preservation of the composer draft after lookup failure.
No live API writes were used for validation. The help template was updated;
the generated help file was not edited.

## Assessment

**Arcanum support is implemented partially, but is not ready for reliable inline
review workflows.** Detection, discussion fetching, replies, edits, and deletion
have implementations. Local anchoring and new-comment validation remain tied to
Git. Inline posting additionally contains incompatible API identifiers and data
shapes. Several advertised platform limitations are actually missing Parley
features: public API issue resolution exists, and plugin API reactions and review
actions exist.

## Feature inventory

| Feature | Current Parley state | Important limitation |
|---|---|---|
| Arc repository detection | Implemented; Arc detector registered before Git | Uses `arc root`, then `arc info --json`; no remote branch means inactive |
| Branch-to-PR detection | Implemented | Prefix query with `limit=1`, then exact matching; no cursor continuation |
| Authentication | Implemented | `ARCANUM_TOKEN`, then `~/.arc/token`; other Arc credential conventions not covered |
| HTTP | Async HTTPS through Plenary/curl | Arc CLI is used for local detection, not HTTP requests |
| Discussion fetching | Implemented | V1 review-request comments; incomplete tree/anchor normalization |
| Signs, discussion float, navigation, quickfix, Telescope | Shared implementation available | Arc remapping is broken; non-file discussions receive invalid placeholder locations |
| Nested discussion rendering | Renderer supports parent IDs | Arcanum mapper drops deeper replies before rendering |
| Replies | Implemented, including callback entry point | Transport failures/cancellation need repair |
| Edit/delete | Implemented | Ownership derives from Arc login rather than authenticated API identity |
| New line/range comments | Provider methods exist | Blocked by shared Git checks, then multiple API-contract defects |
| Read reactions | Implemented | Raw Arcanum codes are not normalized to GitHub-oriented UI choices |
| Add/remove reactions | Explicit error stub | Plugin API implements it; not wired into Parley |
| Read resolved state | Partial | Only `resolved` maps to true; dropped/non-issue states collapse to unresolved |
| Resolve/reopen | Explicit error stubs | Public PATCH API supports issue-status changes |
| Review approval/request changes | Explicit error stub | Plugin API has ship/block-merge actions; semantics and permissions need explicit mapping |
| Review status | Coarse approximation | Merged means approved; an open approved PR still maps to pending |
| Disk cache/shared review data | Implemented generically | Identity excludes host, viewer, and local checkout; mappings are shared across checkouts |
| BufEnter/manual refresh | Implemented | `refresh_interval` is declared but has no runtime consumer |
| Diffview | Detection only | Review/provider repositories require `kind == "regular"` |
| Health check | GitHub-oriented | Does not probe Arc or Arcanum auth, despite README claims |

Main implementation: [provider](lua/parley/providers/arcanum/provider.lua),
[detector](lua/parley/providers/arcanum/vcs_detector.lua),
[mapping](lua/parley/providers/arcanum/mapping.lua),
[transport](lua/parley/providers/arcanum/transport.lua),
[auth](lua/parley/providers/arcanum/auth.lua),
[setup](lua/parley/init.lua), [health](lua/parley/health.lua).

## Verified blockers and defects

### 1. Shared workflows still assume Git

[anchor.lua](lua/parley/anchor.lua) runs `git diff` for every provider. Both fresh
and cached reviews enter this path through
[repositories/review.lua](lua/parley/repositories/review.lua). A failed diff becomes
identity mapping with confidence 1 and `stale=false`: incorrect locations can
appear authoritative. Disk diffs also omit unsaved buffer edits.

[services/write.lua](lua/parley/services/write.lua) calls Git-only
`check_sync_state` and `check_anchor_in_diff` from [vcs.lua](lua/parley/vcs.lua).
It reads `review.write_context.head_sha`; Arcanum supplies `review.head_sha` and
does not duplicate it inside its write context. Thus new-comment composition
fails in Arc even before the API request is constructed.

Recommended design: a VCS adapter owns local revision, file state and revision
diff operations; pure hunk mapping consumes its result. The shared review revision
belongs in one typed field. A failed diff must produce unavailable/stale mapping,
not success. Remote discussion data and checkout-specific mappings need separate
cache identities.

### 2. Active-diff response fields are not requested

`detect_pr` requests `/v1/pull-requests/{id}/active-diff` without `fields`, then
reads `id`, `gsid`, and `commit_ids.head`. In server source,
`PullRequestActiveDiffResource` uses `DiffDto::fromDiffSet`; those fields are all
opt-in, and `ResponseWrapper` defaults to an empty `FieldsFilter`.

Request the actual required fields explicitly, e.g.
`?fields=id,commit_ids(head,base,merge)`. Do not treat missing revision data as
a valid writable review.

**Important exception:** the V2 changelist defaults DO include `path` and
`entry_id` (`DiffSetChangeConverter`). Likewise the V1 PR's selected `vcs` field
includes its branch fields by default. These are not equivalent missing-field
bugs; check each converter instead of applying a blanket sparse-fields rule.

### 3. `gsid` is not `diff_set_xid`

Parley sets `write_context.diff_set_xid = diff_data.gsid`, including test fixtures
such as `ARC:DEADBEEF`. Arcanum's `DiffSetXid.fromString` accepts a decimal target
diff ID or a `base-target` numeric pair. The V1 comment anchor builder invokes
this parser. `ARC:DEADBEEF` fails it. For an active diff, the relevant XID is
normally the string form of the numeric diff ID, not its GSID.

### 4. V2 entry IDs are sent to a V1 endpoint with a different schema

Parley obtains a serialized string `entry_id` from
`/v2/public/diff/{id}/changelist`, then sends it to
`POST /v1/public/review-requests/{id}/comments`.

That V1 request declares `entry_id` as `PublicEntryIdDto`: an object containing
before/after content identifiers, whitespace mode, entry type and operation type.
It does not accept the V2 `eid:...` string shape. This is independent of the GSID
bug. Prefer keeping changelist and inline creation in the same API family, such
as the V2 diff-comment endpoint, with explicit response fields and corresponding
response mapping. Do not merely change the URL: V2 uses `line`, `size`, `side`
and a different anchor structure.

Server evidence for 2–4:
[active diff resource](https://a.yandex-team.ru/arcadia/arcanum/server/arcanum-server-web/src/main/java/ru/yandex/arcanum/web/api/diff/PullRequestActiveDiffResource.java),
[DiffDto](https://a.yandex-team.ru/arcadia/arcanum/server/arcanum-server-web/src/main/java/ru/yandex/arcanum/web/api/model/DiffDto.java),
[DiffSetXid](https://a.yandex-team.ru/arcadia/arcanum/server/arcanum-diff-set/src/main/java/ru/yandex/arcanum/diffset/DiffSetXid.java),
[V1 creation DTO](https://a.yandex-team.ru/arcadia/arcanum/server/arcanum-server-web/src/main/java/ru/yandex/arcanum/web/api/comment/PublicCreateReviewRequestCommentRequestDto.java),
[V1 entry ID](https://a.yandex-team.ru/arcadia/arcanum/server/arcanum-server-web/src/main/java/ru/yandex/arcanum/web/api/comment/PublicEntryIdDto.java),
[V2 changelist converter](https://a.yandex-team.ru/arcadia/arcanum/server/arcanum-server-web/src/main/java/ru/yandex/arcanum/web/v2/diff/DiffSetChangeConverter.kt).

### 5. Inline intent silently becomes a general comment

Both top-level posting methods send only `{content=...}` when entry ID or diff
identity cannot be obtained. A failed changelist lookup therefore changes the
meaning of the user's action without confirmation. The resulting comment has no
line location and may disappear from the current discussion view. Require a valid
inline anchor before submitting; preserve the draft with an actionable error.

The callback method additionally performs `resolve_entry_id` through the
coroutine-only transport before starting the callback request. It is invoked from
the composer's submit callback, outside a Plenary coroutine. A cold changelist
can consequently yield across a non-coroutine boundary. Make prerequisite lookup
part of the same asynchronous operation.

### 6. Nested replies and anchor semantics are lost

`group_comments_into_discussions` indexes only roots, then looks up each reply's
immediate parent in that root index. Root → reply → reply loses the third comment.
Replies appearing before their root are also dropped. Arcanum's server stores the
actual replied-to comment ID, not necessarily the root ID.

`extract_anchor_location` discards old/new side and diff identity. An old-side
comment is treated like a new-side location, and historical/deleted/renamed-file
anchors lack sufficient context. Root comments without positions become
`file=""`, `line=0`; shared listing code constructs a location from those values.

Use a two-pass parent graph and explicit anchor variants: inline, whole-file,
general, outdated/unavailable. Keep revision and side until projection into a
specific buffer. Preserve orphan comments rather than silently deleting them.

### 7. Transport robustness is incomplete

- `timeout_ms` is read but never passed to HTTP/curl or an operation timer.
- Neither HTTP path installs Plenary's `on_error`. The installed Plenary raises
  on nonzero curl exit instead of calling the success callback; awaits or progress
  can remain unfinished. The callback transport's synthetic `curl exit N` error
  also cannot match its textual network-retry patterns.
- Cancellation clears retry timers and delivers a cancelled result, but discards
  the returned curl job and never stops it. The server may still accept the write.
- Retries include POST requests on transient statuses without an idempotency key.
- 429 receives short exponential retries, without request pacing or server-header
  handling. The maintained documentation source specifies default user limits of
  1 RPS (robots: OAuth 5 RPS, TVM 10 RPS), making bursts material for editor use.
- `providers.arcanum.host` is documented but not passed by automatic provider
  construction: detection returns no host and the factory gets only detection opts.

Use one transport implementation for coroutine and callback callers, an exactly-once
completion guard, a retained cancellable job, error callbacks, explicit deadlines,
and a shared rate scheduler. Use a stable idempotency key per submit/retry operation.
Cancellation after sending must not promise that the server rolled the action back.

The server source and documentation support `Idempotency-Key` on create/reply:
first create 201, replay 200, conflicting payload 409, retention approximately
72 hours. Check deployment support before relying on this for write guarantees.
[Public API documentation source](https://a.yandex-team.ru/arcadia/arcanum/docs/communication/public-api.md).

## Missing features that Arcanum can support

**Resolve/reopen:** `PATCH /v1/public/review-requests-comments/{comment_id}` accepts
`{"issue_status":"resolved"}` or `{"issue_status":"open"}`. Arcanum's own MCP
implements closing via this endpoint. Parley's unsupported claim is contradicted
by both the request DTO and server handler. Add issue-state normalization too:
`dropped`, `not_issue` and absent status should not automatically inflate an open
issue count. Resolving requires service/UI wiring as well as replacing the stub.
[MCP client](https://a.yandex-team.ru/arcadia/arcanum/mcp/lib/arcanum_api.py),
[public update handler](https://a.yandex-team.ru/arcadia/arcanum/server/arcanum-server-web/src/main/java/ru/yandex/arcanum/web/api/comment/PublicCommentForReviewRequestsResource.java).

**Reactions:** plugin API implements PUT/DELETE on
`/v1/plugin/diff/{diff_id}/comment/{comment_id}/reaction/{code}` and a separate
PR-comment route. These require `GENERIC_WRITE`; AI-review comments have additional
validation. Preserve the correct comment/diff identity, normalize reaction codes,
and make available UI actions provider-dependent.
[Reaction resource](https://a.yandex-team.ru/arcadia/arcanum/server/arcanum-server-web/src/main/java/ru/yandex/arcanum/web/plugin/api/PluginDiffReactionResource.kt).

**Review actions:** plugin API provides PUT/DELETE `.../review/ship`, PUT/DELETE
`.../review/block-merge`, and GET review data. Ship/block require
`REVIEW_REQUEST_SHIP`; normal ship applies to the active diff, while `sticky=true`
uses PR-level approval. Map these intentionally to Parley's review model; GitHub's
review body/event transaction does not have an established one-to-one equivalent.
[Review resource](https://a.yandex-team.ru/arcadia/arcanum/server/arcanum-server-web/src/main/java/ru/yandex/arcanum/web/plugin/api/PluginReviewResource.kt).

**Drafts, publication and suggestions:** Arcanum supports drafts, publishing draft
comments, whole-file/old-side comments and commit suggestions. Parley exposes no
Arcanum workflow for these. They are optional scope extensions after core reliability.
Comment IDs may be negative; preserving them as strings is appropriate.
[V2 reference](https://a.yandex-team.ru/arcadia/arcanum/server/arcanum-server-web/src/main/java/ru/yandex/arcanum/web/v2/README.md).

## Existing TODOs and documentation drift

- [TODO.md](TODO.md): resolve/unresolve and unresolved count, rate limits,
  Diffview, consistent setup options, stale-position UI, typing, documentation
  coverage and test isolation. No dedicated Arc compatibility checklist exists.
- Telescope discussion pickers are still listed as TODO although implemented.
- [PROJECT.md](PROJECT.md) describes Arcanum as future work; [README.md](README.md)
  says GitHub only while listing Arcanum detection.
- README says requests use `arc`; implementation uses direct HTTPS.
- [Help template](doc/parley.nvim.txt.in) claims login comes from `arc config -l`
  and PRs are filtered by author. Code uses `arc info --json.user_login` and remote
  branch prefix plus exact branch comparison; there is no author filter.
- README claims Arc health checks; health code checks Git/GitHub only.
- Help's public-API resolution limitation is false against the inspected server.
- `refresh_interval`, Arcanum `timeout_ms`, and auto-detected `host` need working
  configuration paths, not just documented defaults.
- [http.lua](lua/parley/http.lua) refers to `POSTPONED.md`, which is absent.

## Prioritized implementation backlog and regression protection

1. **Make local VCS operations polymorphic. — Implemented.** Arc detection alone is insufficient.
   Test the complete Arc read/write workflow with Git unavailable; use the shared
   revision field, distinguish VCS failure from unchanged content, and account for
   unsaved buffers and separate checkouts.
2. **Fix the inline API contract as one unit. — Implemented.** Explicit active-diff fields,
   correct numeric XID, compatible entry-ID/creation schemas, async prerequisite
   lookup, and refusal to silently post a general comment. Test realistic wire
   fixtures and request bodies, including empty/sparse responses and stale diffs.
3. **Harden transport before enabling more writes. — Implemented.** Error callbacks, actual
   timeouts, cancellation, pacing, and idempotency. Test lost-response retry,
   cancellation races, 429, nonzero curl exit, and exactly-once completion.
4. **Preserve discussion semantics. — Implemented.** Two-pass tree grouping, old/new side,
   historical revision, general/file comments, dropped/non-issue state. Test
   grandchildren, arbitrary ordering, missing parents, renames and deleted files.
5. **Implement resolve/reopen and provider capabilities. — Implemented.** Hide or explain unavailable
   actions before users compose or choose them. Keep capabilities and command/help
   documentation in one source of truth.
6. **Complete detection/configuration/health. — Implemented.** Paginate prefix search until exact
   match; test competing prefix branches, absent upstream, alternate token sources,
   authenticated-viewer mismatch, host propagation and multiple checkouts.
7. **Add reactions and review actions deliberately. — Implemented.** Validate token scopes and
   ordinary versus sticky ship; normalize review status and reaction vocabulary.
8. **Update README, PROJECT, TODO and the help template together.** Then tackle
   Diffview and optional drafts/suggestions as explicit follow-up scope.

Installed Arc version: `20036045 (2026-06-24)`. Its help confirms `diff -U`,
`--git`, `--no-color`, `--cached`, `--base`, `--json`, and `--relative`; `status
--json` and `rev-parse` also exist. These provide adapter building blocks, but
their working-copy/index/revision semantics need fixture tests before translating
Git commands mechanically. No synchronous HTTP is necessary.

## Validation and remaining uncertainty

- Existing Arcanum tests: **92 passed, 0 failures/errors** (mapping 43, auth 9,
  detector 11, provider 29), using an installed Plenary checkout and a temporary
  Neovim init; `.tests/plenary.nvim` was absent.
- No Arcanum transport test file exists. Provider tests do not cover top-level
  posting or callback entry points. Tests currently encode the incorrect GSID/XID
  assumption and expected unsupported errors.
- Temporary mocked reproductions confirmed: 3-level thread retains only 2
  comments; reply-before-root retains only the root; old/new anchors normalize
  identically; failed VCS mapping reports confidence 1; missing inline metadata
  sends only content; configured timeout/on_error are absent and cancellation does
  not stop the curl job. No actual network writes were made.
- This was research, not a code change: no full CI or formatter mutation was run.
- Live endpoint deployment, OAuth permission coverage, API rate-limit headers and
  representative production response fixtures remain unverified. Existing mocked
  unit-test success is not evidence of end-to-end Arc compatibility.

## Encountered difficulties

The sandbox could not resolve internal search; approved network access made search
available. The Docs connector returned `Tool 'read_page' not found on server`, so
API claims were verified against exact source files discovered through search and
links. Documentation and mocked fixtures contradicted server types, especially
resolution support, diff identifiers and sparse-field defaults. Published-page
parity remains unverified.

### Where to report

If you're sure the reported difficulties above are related to techplatform (e.g. userver, c35),
please report to [aisuite](https://nda.ya.ru/t/EcUMOwSH7eudWX).
