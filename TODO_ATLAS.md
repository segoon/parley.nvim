# PR discussion comparison: Parley and Atlas

Research date: 2026-10-04.

This is a source-based research reference for building an implementation plan,
not an approved implementation plan or a promise of provider compatibility.
Atlas is assumed to be checked out at **`~/projects/atlas.nvim/`**. Paths beginning
with `lua/atlas/`, `spec/`, or `bin/atlas-notes` below are relative to that Atlas
root; Parley paths and Markdown links are relative to this repository.

## Scope and evidence

Included: PR/MR discussions, comment locations, composition, replies, editing,
deletion, resolution, reactions, unpublished review comments, suggestions, local
notes, navigation, diff integrations, and the transport/cache behavior supporting
those workflows. Review submission is included only where it publishes comments.

Excluded: GitHub Actions and other CI systems, standalone issues/Jira, repository
browsing, notifications, PR creation/merge/administration, and standalone verdict
management. Arcanum's term "issue" can describe a review discussion's state; that
meaning remains in scope.

Evidence labels used in the findings:

- **Probe-confirmed:** reproduced in an isolated Neovim process with mocked
  subprocesses/storage, without contacting a provider.
- **Source-confirmed:** supported by inspected implementation/control flow;
  the complete behavior was not exercised against a live deployment.
- **Audit lead:** worth testing, but not established as a demonstrated bug.
- **Candidate:** proposed Parley work, not existing functionality.

The research inspected local source, docs, configuration, and representative
tests. It did not inspect Git history, invoke Git, install dependencies, or make
live API requests. No repository files were changed during the original research;
this file is the subsequent requested research artifact. Recheck symbols and
behavior before planning changes because the checkouts may evolve.

## Main conclusions

1. Parley has the stronger integration with ordinary working buffers: discussion
   positions follow local and unsaved edits, with buffer/review navigation and
   careful handling of drafts and stale contexts.
2. Atlas has the broader discussion feature set inside dedicated review views:
   general conversation, both diff sides, file comments, unpublished review
   comments, suggestion authoring, templates, mentions, and private notes.
3. Parley's Arcanum implementation preserves richer discussion semantics than its
   GitHub implementation. Do not generalize either provider's behavior to both.
4. Parley has much more automated lifecycle/UI testing, but its GitHub adapter
   still has correctness and write-safety defects. Atlas's breadth does not imply
   complete provider parity or robust failed-write recovery.
5. Preserve Parley's working-buffer focus. Borrow discussion capabilities without
   adopting Atlas's entire dashboard/application scope.

## Feature comparison

| Concern | Parley | Atlas | Planning implication |
|---|---|---|---|
| Discussion providers | GitHub and Arcanum | GitHub, GitLab, Bitbucket Cloud | GitLab/Bitbucket would be separate provider projects, not small UI additions |
| VCS | Git and Arc adapters | Git | Preserve provider/VCS separation |
| Entry point | Detect current branch's review in a supported checkout | Select/search/open a review, including by URL | Explicit review selection could complement automatic discovery |
| Ordinary working files | Signs, virtual text, hover, discussion float | No equivalent automatic integration found | Keep Parley's distinguishing workflow |
| Local/unsaved edits | Remap locations against buffer/working-file content | Primarily use explicit review/diff revisions | Do not replace Parley's mapping with raw Atlas line numbers |
| Diff viewers | Diffview | Native AtlasDiff, CodeDiff, Diffview | CodeDiff is the clearest integration gap |
| General PR conversation | GitHub review comments only; Arcanum can retain general discussions | General conversation as well as inline threads | Add GitHub general comments with distinct identity/semantics |
| New inline comments | New side, eligible changed lines; clean/synchronized source | Both sides and ranges | Expand anchor support before relaxing validation |
| New whole-file comments | No built-in creation workflow | Implemented in provider comment paths | Distinguish file comments from invented line-1 comments |
| New general comments | No equivalent general-comment composer workflow | Supported | Never silently fall back to general posting after inline validation fails |
| Existing locations | Arcanum: explicit side/path/revision/history; GitHub: lossy mapping | GitHub: side, range, file subject, outdated metadata | Fix GitHub normalization first |
| Replies | Shared tree rendering; Arcanum retains complex parent graphs | Threaded comments and previews | Preserve orphan/cycle handling and parent identity |
| Edit/delete | Implemented, with ownership/capability checks | Implemented, provider-dependent | Preserve drafts and distinguish write acknowledgement from refresh failure |
| Resolve/reopen | GitHub threads; eligible complete Arcanum root issues | Provider discussion operations | Capability availability must include state constraints |
| Reactions | GitHub add/remove via toggle; Arcanum explicit desired state | GitHub/GitLab add operations; no Bitbucket reaction capability found | Unify explicit add/remove intent rather than copying toggle semantics |
| Unpublished review comments | No complete user workflow | GitHub/GitLab; Bitbucket creation exists but publication hands off to browser | Separate server drafts from optimistic in-flight comments |
| Suggestion comments | No dedicated authoring/rendering/application workflow | Dedicated authoring and rendering | Authoring, rendering, and applying are separate deliverables |
| Apply suggestions | Backlog item | No apply-suggestion action found | Do not describe application as existing Atlas parity |
| Private notes | No separate notes system | Persistent typed local notes and CLI | Optional feature with its own storage/identity contract |
| Reviewed files | No workflow | Local tracking; GitHub remote viewed-state support | Optional navigation aid, with explicit local/remote distinction |
| Navigation | Per-buffer/review, unresolved filtering, quickfix, built-in picker, Telescope | Diff comments, file explorer, review panel, notes | Improve context/filters while preserving normal-buffer navigation |
| Browser links | Exact review/discussion/comment links where available | Browser opening and URL copying | Copy-link support is a small independent improvement |
| Composition helpers | Markdown input, optional render-markdown integration | Markdown input, templates, author completion, context preview | Templates/mentions can be independent additions |
| Refresh | Buffer entry, manual, after writes, visible-review polling | Open/manual/action-driven refresh and cancellable request scopes | Preserve Parley's visibility-aware polling |
| Failed draft recovery | Shared transaction lifecycle restores drafts | Editor closes before acknowledgement; failure path lacks recovery | Preserve Parley's stronger behavior when adding new workflows |

### Provider boundaries and non-parity

- Parley's built-in GitHub detector accepts `github.com` only. Its explicit
  Enterprise constructor is not sufficient for reliable host routing; see P-03.
  Atlas explicitly routes GitHub subprocesses with `GH_HOST` from configuration.
- Atlas GitLab supports a configured host. Its thread-detail implementation uses
  GraphQL fields noted in source as requiring GitLab 19.1+ for diff snippets.
  This was not validated against live installations; REST API v4 alone does not
  establish full feature compatibility.
- Atlas Bitbucket targets Cloud API 2.0. No Server/Data Center implementation was
  found. Its pending-review publication is a browser handoff, not API completion.
- Atlas exposes comment reaction addition for GitHub/GitLab. Do not infer removal
  from a generic "react" label. Bitbucket's comment capability omits reactions.
- Arcanum retains general, whole-file, historical, old-side, nested, orphaned,
  and cyclic discussion information. Such readability does not imply support for
  creating new discussions at all those locations.
- Arcanum resolution is limited to complete root issues in open/resolved states.
  Dropped, non-issue, unknown, incomplete, and cyclic discussions remain readable
  but cannot be transitioned as ordinary resolvable threads.

Sources: [Parley provider catalog](lua/parley/providers/init.lua),
[GitHub capabilities](lua/parley/providers/github/capabilities.lua),
[Arcanum discussion grouping](lua/parley/providers/arcanum/discussions.lua),
[Arcanum compatibility](ARCANUM_COMPATIBILITY.md);
Atlas `lua/atlas/providers/init.lua`,
`lua/atlas/pulls/providers/{github,gitlab,bitbucket}/init.lua`, and
`lua/atlas/providers/bitbucket/client.lua`.

## Workflow details to preserve or learn from

### Positioning and creation eligibility

Parley compares review revision content against loaded buffers, including
unsaved edits, or working-tree files. Local changes update positions without
refetching the API. Shared remote snapshots and checkout-specific mappings are
separate. Changed/deleted/unavailable locations carry stale or unavailable state;
historical and unlocated discussions must not acquire fabricated positions.

New inline creation is deliberately stricter than reading existing threads:
the source must be clean, local HEAD must match the pushed source head, and every
selected line must be eligible. Validation runs before composition and again on
submission, checking context/identity and changes during asynchronous validation.
This is useful safety, but it prevents creating comments from arbitrary locally
modified code. Any relaxation requires an unambiguous mapping back to the review.

Arcanum has distinct source `head`, immutable destination `base`, and synthetic
review `merge` revisions. Sync validation uses `head`; review coordinates and
changed-line checks use `base` to `merge`. Source selections may need translation.
A new diff can invalidate a draft even when the source head is unchanged. Preserve
this distinction in any provider-neutral anchor redesign.

Atlas's diff position helper retains old/new paths and side-specific coordinates,
and can calculate the opposite-side coordinate for context lines. Range creation
validates representability of its endpoints. That is not a proof that every
provider accepts every context line/range. Its GitLab creation path checks target
head against available diff refs and rejects a changed head; Atlas is not devoid
of stale-target validation.

Sources: [anchor mapping](lua/parley/anchor.lua),
[submission validation](lua/parley/services/write_validation.lua),
[changed-line validation](lua/parley/providers/comment_target.lua),
[Arcanum inline creation](lua/parley/providers/arcanum/inline.lua);
Atlas `lua/atlas/pulls/diff/position.lua` and
`lua/atlas/pulls/providers/gitlab/api/comments.lua:add_positioned_comment`.

### Three different meanings of pending

These states must not be represented by one ambiguous boolean:

1. **Local draft:** text the user is still composing, not sent to a provider.
2. **In-flight optimistic comment:** a write has started; the result is unknown.
   This is Parley's current visible pending-comment mechanism.
3. **Server-side unpublished review comment:** stored remotely but intentionally
   not published to other participants yet. Atlas supports this for review flows.

Parley's optimistic entries survive refresh only within the matching review
snapshot. Late callbacks must not mutate a replacement review. Definite failure
restores the draft; uncertainty must retain the text and tell the user to inspect
remote state before retrying. Acknowledgement followed by failed hydration must
not create a fresh retryable draft for something already accepted remotely.

Atlas's GitHub immediate inline posting itself uses multiple steps: create a
pending review, add the thread, then submit. If publication fails after creation,
it reports "Comment saved as pending; refresh and submit the review". This is a
useful partial-success distinction to preserve in a richer result type. GitLab
uses draft-note/discussion endpoints. Bitbucket submission differs; see A-03.

Sources: [pending preservation](lua/parley/repositories/review_pending.lua),
[optimistic transactions](lua/parley/repositories/review_mutations.lua),
[write lifecycle](lua/parley/services/write_operation.lua),
[Arcanum acknowledgement handling](lua/parley/providers/arcanum/comment_write.lua);
Atlas `lua/atlas/pulls/providers/github/api/comments.lua:publish_comment` and
`lua/atlas/pulls/providers/gitlab/api/comments.lua`.

### Navigation, rendering, and integration

- Parley's discussion float retains selection through refresh; it does not
  automatically follow the source cursor. Optional hover previews are separate.
- Multiple discussions at one line use a picker. General/unavailable discussions
  remain accessible through the full discussion list. Quickfix omits general
  discussions and keeps unavailable file locations as invalid entries.
- Unresolved filtering already exists in the built-in/Telescope pickers and
  buffer/review navigation. Authored-by-me, mentions, remote-outdated, local-stale,
  and unavailable-location filters are potential extensions, not all current
  features of either plugin.
- Parley Diffview supports discussion rendering/navigation and new-side creation.
  Automatic range construction is Git-only. Matching Arcanum old-side anchors
  can be read; old-side creation is not implemented. File-panel badge refresh
  behavior differs between upstream Diffview and the inspected fork.
- Atlas has explicit adapters for AtlasDiff, CodeDiff, and Diffview. Configuring
  another diff command opens a revision range but does not confer equivalent
  Atlas overlays. External integrations depend on plugin internals.
- Atlas supports ordinary LSP behavior on the native diff's new side by using a
  detached worktree. That machinery is specific to its native viewer; Parley's
  normal-file workflow already uses ordinary editor buffers.
- Atlas emits `AtlasReviewAttached`/`AtlasReviewDetached` and related UI/diff
  events. A public Parley discussion API could avoid third parties depending on
  private repositories/window state.

Sources: [Diffview integration](lua/parley/diffview_integration.lua),
[discussion picker](lua/parley/discussion_picker.lua),
[quickfix](lua/parley/quickfix.lua), [navigation](lua/parley/nav.lua);
Atlas `lua/atlas/pulls/diff/init.lua`, `lua/atlas/pulls/diff/session.lua`,
`lua/atlas/pulls/diff/codediff/`, and `lua/atlas/core/events.lua`.

### Configuration, examples, and documentation

Parley's small configuration surface covers presentation, navigation, polling,
integrations, and transport. Setup registers built-in providers automatically.
Navigation mappings are global; empty strings disable them. Telescope loading is
enabled by default and warns if Telescope is absent. Setup reconstructs defaults
and resets provider registration. Custom registrations must follow setup.

Atlas explicitly enables configured providers: `setup({})` alone does not enable
GitHub. A minimal GitHub configuration is:

```lua
require("atlas").setup({ providers = { github = {} } })
```

Atlas has many more review configuration options: diff layout/panel/explorer,
comment display, templates, keymap aliases/disabling, and custom actions. Its
picker choices are built-in, Snacks, and fzf-lua; Parley integrates Telescope.
Atlas setup merges into the existing configuration rather than resetting it and
sets global `laststatus=3` by default. These side effects should not be copied
uncritically. Neither plugin fully validates every option.

Parley's README, project document, provider compatibility references, and Vim help
describe constraints/failure behavior in more detail. Help is partly generated
from annotations; tests check commands/capability tables. Atlas has richer visual
examples and more review configuration examples, but fewer explicit discussion
transport/compatibility guarantees. Both describe themselves as early-stage.

Documentation/capability checks do not prove a reachable user workflow: Parley's
GitHub submission method has no command/UI caller, and Atlas's Bitbucket submission
function exists but opens a browser. Plan end-to-end availability tests as well as
declaration/documentation checks.

Sources: [Parley setup](lua/parley/init.lua), [README](README.md),
[help template](doc/parley.nvim.txt.in),
[documentation tests](tests/parley/action_documentation_spec.lua);
Atlas `lua/atlas/config.lua`, `lua/atlas/ui/picker/init.lua`, `README.md`,
`doc/atlas.txt`, and `spec/providers/contracts_spec.lua`.

## Parley bug and gap register

### P-01: GitHub range and side information is lost

**Evidence: probe-confirmed. Priority: correctness before new anchor features.**

`group_comments_into_discussions()` uses REST `line` as the discussion start and,
when `start_line` exists, also uses `line` as the end. A probe with
`start_line=10`, `line=20`, `side=LEFT` produced `line=20`, `end_line=20`, and no
explicit anchor. Side loss is documented; range collapse is an additional defect.
The `original_line` fallback also lacks explicit historical/outdated identity.

Source: [GitHub mapping](lua/parley/providers/github/mapping.lua).

Design direction: normalize API locations into one lossless anchor structure
before UI projection. Keep kind, side, start/end, old/new paths, revision/diff
identity, and remote-outdated state separate from local mapping confidence.
Use shared invariants so individual renderers cannot independently reinterpret
REST line fields.

Regression targets: RIGHT/LEFT single lines and ranges; original ranges with
null current locations; file comments; renamed/deleted files; no fabricated
current location; display/navigation consistent with the normalized range.

### P-02: GitHub creation retries ambiguous failures

**Evidence: probe-confirmed transport behavior; duplicate remote writes are a risk.**

Both `gh_run()` and `gh_start()` apply transient-error retries without classifying
the operation as a read or mutation. Defaults allow two retries. A mocked timeout
followed by success caused two comment-creation attempts. If the first attempt was
accepted before its response was lost, a retry can duplicate the comment.
The GitHub path does not classify uncertainty like the Arcanum path.

Sources: [GitHub transport](lua/parley/providers/github/transport.lua),
[creation callers](lua/parley/providers/github/provider.lua),
[Arcanum retry policy](lua/parley/providers/arcanum/transport.lua).

Design direction: pass explicit operation semantics into transport. Default
non-idempotent creation to no automatic retry after dispatch; distinguish
definite failure, uncertain outcome, and acknowledgement. Enable keyed retries
only where a provider's actual contract supports them. Do not infer safety from
HTTP method alone or copy an Arcanum-specific key scheme into GitHub.

Regression targets: accepted-but-response-lost creation; timeout before dispatch;
cancellation while queued/in flight; successful acknowledgement plus failed
hydration; a late callback; no duplicate automatic creation; text retained with
an accurate message. Audit replies, edits, deletion, resolution, and reactions
using the same transport.

### P-03: Configured GitHub host/API base is not bound to API execution

**Evidence: probe-confirmed command construction and source-confirmed spawn options.**

The explicit constructor stores `host` and `api_base` and uses them in identity,
but API requests use relative `gh api` endpoints without `--hostname`, and default
spawn options do not bind `GH_HOST`. Captured Enterprise discovery commands
contained no configured host. Routing depends on ambient CLI behavior rather than
the provider's configured identity. Automatic Enterprise detection is separately
unsupported; fixing routing does not automatically add detection.

Sources: [provider constructor/requests](lua/parley/providers/github/provider.lua),
[cache identity](lua/parley/providers/github/cache_identity.lua),
[compatibility claims](GITHUB_COMPATIBILITY.md).

Design direction: make host/account routing a mandatory transport property,
consistent with authentication and cache identity. Explicitly define whether a
custom API base is supported. Apply the same routing to coroutine and callback
paths. Atlas's GitHub client binds `GH_HOST` per subprocess and has routing tests.

Regression targets: ambient host different from configured host; REST/GraphQL;
callback/coroutine paths; account change; custom API-base behavior; no requests to
an unintended host. Update docs to match tested support.

### P-04: GitHub review-status failure prevents discussion discovery

**Evidence: probe-confirmed.**

`detect_pr()` fetches `/reviews` without a protected degradation path. A successful
PR lookup followed by a forbidden review-status response aborts detection. On a
cold load this prevents fetching otherwise readable discussions. Existing cached
data may remain available through repository-level failure handling.

This conflicts with the general claim that failed status reads become unknown
without hiding readable discussions. Arcanum explicitly performs that degradation;
GitHub does not. The status calculation also picks the last recognized review:
Alice requesting changes followed by Bob approving becomes `approved`. Treat that
as a last-event summary, not aggregate approval/merge readiness.

Sources: [GitHub discovery](lua/parley/providers/github/provider.lua),
[status mapping](lua/parley/providers/github/mapping.lua),
[Arcanum status read](lua/parley/providers/arcanum/review_actions.lua).

Design direction: separate required review identity/discussion reads from optional
status enrichment. Preserve unknown/partial states instead of collapsing the
whole read. If status remains visible, define its semantics explicitly.

Regression targets: failed/malformed optional status response on cold and warm
loads; discussions remain available; status unknown; separate reviewer verdicts
are not mistaken for authoritative readiness.

### P-05: GitHub review submission is not a complete user workflow

**Evidence: source-confirmed feature gap, not a demonstrated API failure.**

`GitHubProvider:submit_review()` exists, but no production command/UI/service caller
was found. `:Parley review actions` uses a different capability, unavailable for
GitHub. There is also no end-user accumulation/publication workflow for unpublished
inline comments. Do not mark this capability complete solely because a provider
method or help support table exists.

Sources: [commands](lua/parley/commands.lua),
[GitHub capabilities](lua/parley/providers/github/capabilities.lua),
[provider method](lua/parley/providers/github/provider.lua),
[review-action UI](lua/parley/review_actions.lua).

Design direction: when implementing batch comments, model creation, publication,
discard, recovery, and partial success as an explicit lifecycle. Test reachability
from the public UI as well as provider contracts.

### P-06: GitHub reactions do not preserve explicit add/remove intent

**Evidence: source-confirmed; correction to an overbroad earlier comparison.**

Parley's picker captures desired presence. The service forwards that intent to
providers implementing `begin_set_reaction`, including Arcanum. GitHub lacks that
method and falls back to `react()`, which reads reactions and toggles based on the
fresh result. Its REST mapping initializes `viewer_reacted=false`, so picker state
also does not establish current viewer ownership. GitHub supports removal, but
not the same explicit desired-state guarantee as Arcanum.

Sources: [reaction selection](lua/parley/reactions.lua),
[service dispatch](lua/parley/services/comment_actions.lua),
[GitHub reaction implementation](lua/parley/providers/github/provider.lua),
[reaction mapping](lua/parley/providers/github/mapping.lua).

Design direction: use a desired-state operation for every provider, with ownership
hydrated or explicitly unknown. Avoid reinterpreting an add request as remove
after a concurrent refresh/change. Audit reaction pagination as part of this work.

Regression targets: existing viewer reaction, unknown ownership, remote change
between selection and submission, repeated submission, and cancelling a pending
lookup without silently flipping the intended operation.

## Atlas defects and limits to avoid copying

### A-01: Composer text is discarded before write acknowledgement

**Evidence: probe-confirmed editor lifecycle; source-confirmed error path.**

The Markdown editor uses `bufhidden=wipe`. Save invokes `on_save()` then closes
immediately, without awaiting success. A probe confirmed both buffer and window
were invalid immediately after starting save. `pulls/actions/review.lua` reports
comment failures but does not reopen or preserve a recoverable draft.

Sources: Atlas `lua/atlas/ui/popups/editor/init.lua:save_and_close` and
`lua/atlas/pulls/actions/review.lua:add_comment`.

Lesson: draft ownership must be independent of window lifetime. Closing the
composer during a request can be good UI if a transaction still owns the text and
can restore/reconcile it. Parley's existing lifecycle should remain the baseline.
Apply this invariant to suggestions, replies, edits, general comments, and batches.

### A-02: Cache keys do not consistently isolate host/account identity

**Evidence: probe-confirmed GitLab cache collision; source-confirmed key construction.**

GitHub keys include host but not account. GitLab passes keys through without adding
host/account scope; `gitlab:current_user` is one example. With mocked storage,
changing GitLab host/token still returned the previous user's cached record.
Bitbucket also has unscoped user-cache keys. This can confuse ownership and reuse
stale discussion data; it is not evidence of a server authorization bypass.

Sources: Atlas `lua/atlas/providers/github/client.lua:cache_key`,
`lua/atlas/providers/gitlab/client.lua`,
`lua/atlas/providers/gitlab/users.lua:fetch_user`, and
`lua/atlas/providers/bitbucket/users.lua`.

Lesson: make provider/host/repository/account scope mandatory for every cache and
in-flight response, including viewer and completion caches. Parley's identity
boundaries should extend to new notes/drafts APIs where appropriate; decide
explicitly whether private notes are account-specific or shared locally.

### A-03: Bitbucket pending-review submission is a browser handoff

**Evidence: source-confirmed.**

`submit_review()` opens the PR URL, ignores the supplied body, and reports success.
It does not publish pending comments through the API. A capability function's
presence therefore overstates completion if interpreted as API submission.

Source: Atlas `lua/atlas/pulls/providers/bitbucket/api/reviews.lua:submit_review`.

Lesson: model `unsupported`, `browser_handoff`, `saved_unpublished`, and `published`
as different results. UI messages and draft cleanup must follow the real outcome.

### A-04: Transport has no configured deadlines and inconsistent decoding failure

**Evidence: source-confirmed absence of transport deadlines; probe-confirmed JSON fallback.**

Common curl requests have no configured total timeout, retry policy, or rate-limit
scheduler. GitHub subprocess requests have no timeout. In the GitHub JSON path,
decode failure falls through to returning stdout with no error; a probe returned
`"not json"` as a successful result. Some callers validate the type, others assume
structured data. This weakens error reporting and completion guarantees.

Sources: Atlas `lua/atlas/core/http.lua` and
`lua/atlas/providers/github/client.lua:run`.

Lesson: require typed/validated transport results and bounded operation lifetimes.
Keep cancellation, deadline, decoding, API errors, and uncertain writes distinct.
Do not confuse pipeline retry features with transport retries.

### A-05: Nested pagination is incomplete for GitHub discussions

**Evidence: source-confirmed.**

GitHub review threads paginate, but each thread requests `comments(first:100)`
without a nested cursor/page-info traversal. Long threads can therefore be
incomplete even when all thread pages were fetched.

Source: Atlas `lua/atlas/pulls/providers/github/api/reviews.lua:REVIEW_QUERY` and
`:fetch_comments`.

Lesson: pagination completeness is a property of each nested collection, not the
outer request. Test more than one page of threads and more than one page of replies
inside a single thread. Preserve readable partial data with an explicit indicator
if a later page fails.

### A-06: Multi-step operations can partially succeed

**Evidence: source-confirmed sequencing; not a live failure reproduction.**

GitHub immediate comments can be stored pending before publication fails; that
path reports the distinction. GitLab combined review publication/approval uses
separate requests: comments can publish before the following operation fails.
Bitbucket combined verdict/comment operations similarly use separate writes.
The standalone verdicts are outside this document's feature scope, but their
sequencing matters when evaluating whether discussion text is already published.

Sources: Atlas `lua/atlas/pulls/providers/github/api/comments.lua:publish_comment`,
`lua/atlas/pulls/providers/gitlab/api/reviews.lua:approve`, and
`lua/atlas/pulls/providers/bitbucket/api/reviews.lua:approve`.

Lesson: use structured partial-success results and reconcile remote state before
retrying an entire workflow. Do not restore already-published text as a new,
apparently unsent comment.

## Open audit leads, not established bugs

- **Parley GitHub pagination decoding:** discussion reads use `gh api --paginate`
  and transport decodes stdout once. Validate the actual installed/supported CLI
  output for multiple REST pages rather than assuming mocked single-page JSON
  proves pagination. The research did not establish a runtime pagination failure.
  Also define the minimum CLI version required by any proposed `--slurp` solution.
- **Parley GitHub reply ordering:** grouping only appends a reply if its root has
  already been seen. Out-of-order/orphan replies are dropped by this implementation.
  Verify real ordering guarantees and add shuffled-page/orphan fixtures before
  deciding whether to reuse the generic graph grouper.
- **GitHub resolution after metadata failure:** REST comments remain readable if
  the GraphQL overlay fails, but default resolution becomes false. The provider's
  thread-node lookup is accumulated rather than visibly reset per fetch. Test
  repeated success/failure sequences and represent unknown resolution explicitly
  if appropriate; do not assume the compatibility prose proves those semantics.
- **Atlas outdated locations:** `diff/position.lua:comment` may reuse an outdated
  comment's line when it is still inside file bounds. It does not demonstrate a
  content-based relocation to the correct current code. Test moved code before
  treating an outdated badge as solved anchor recovery.
- **Cancellation coverage:** Atlas scopes suppress callbacks after cancellation,
  but not every mutation uses the same owning scope. Parley's fallback coroutine
  operations can suppress application without cancelling the server write.
  Audit each discussion operation rather than asserting universal cancellability.
- **Very large/malformed discussions:** test repeated pagination cursors, duplicate
  IDs, missing parents, cycles, malformed successful payloads, and partial pages
  against each provider. Arcanum already has substantially more explicit coverage.

## Candidate Parley work

The IDs below are planning handles. They are not commitments or a chronological
task list. Several are already mentioned in [TODO.md](TODO.md); reference or refine
those items instead of treating this as a second independent backlog.

| ID | Candidate | Value | Dependencies / decision |
|---|---|---|---|
| C-01 | Lossless GitHub anchors and outdated-state handling | Correct locations and enable both-side/file features | P-01; common anchor invariants |
| C-02 | Consistent GitHub transport identity and write safety | Prevent wrong routing and duplicate writes | P-02/P-03/P-06; typed outcomes |
| C-03 | General GitHub PR conversation | Read/reply beyond inline review threads | Distinct comment kinds/IDs/endpoints; no inline fallback |
| C-04 | Old-side and whole-file creation | Review deletions and file-wide concerns | C-01; provider-specific eligibility |
| C-05 | Unpublished comments and batch publication | Compose a coherent review before publishing | P-05; lifecycle/identity/reconciliation design |
| C-06 | Suggestion authoring and structured rendering | Create and understand proposed edits | Range semantics, provider formatting, composer recovery |
| C-07 | Preview/apply suggestions locally | Address feedback without manual copying | C-06; matching/rejection rules and one-step undo |
| C-08 | Context previews, templates, mentions | Improve composition without leaving code | Provider completion contract; configurable helpers |
| C-09 | Richer filters and discussion selection | Work through large reviews efficiently | Known/unknown ownership and distinct stale states |
| C-10 | Outdated discussion recovery | Understand comments after code moves | C-01; historical content and explicit approximation |
| C-11 | CodeDiff adapter | Bring Parley discussions to another review viewer | Stable lifecycle/identity API; integration fixtures |
| C-12 | Provider-neutral discussion integration API | Let other UI plugins consume Parley safely | Defined snapshots/events and subscription lifetime |
| C-13 | Local private notes and optional CLI | Capture feedback before posting or for private use | Scope decision; durable schema and concurrency |
| C-14 | Reviewed-file progress | Improve systematic traversal of large reviews | Decide local versus provider-backed semantics |
| C-15 | Copy exact discussion/comment links | Share/bookmark locations cheaply | Provider-owned URL availability |
| C-16 | Explicit review selection/by-URL attachment | Discuss a review not auto-selected from the branch | Checkout/revision identity and multi-review lifecycle |
| C-17 | Additional discussion providers | GitLab or Bitbucket users | Independent provider contracts/live validation |

### Candidate requirements and useful Atlas references

**C-03: General conversation.** GitHub PR conversation comments use a different
API family from review comments. Preserve kind and canonical URL; scope IDs to
their entity kind so collisions cannot cross edit/delete/reaction endpoints.
General discussion navigation should not invent a source-file line. Include the
conversation in pickers/panels while keeping quickfix semantics intentional.
Atlas: `lua/atlas/pulls/providers/github/api/comments.lua:add_comment`,
`api/activity.lua`, and `lua/atlas/pulls/ui/detail/tabs/conversation/`.

**C-04: New anchor kinds.** Support must be declared per provider and location kind,
not inferred from a single `post_top_level_comment=true`. Old-side selections must
remain tied to an immutable base revision. Preserve Arcanum's source/merge
distinction; reading old-side anchors does not authorize posting them.
Atlas: `lua/atlas/pulls/diff/position.lua`, `diff/comments.lua:add_to_file`, and
provider `api/comments.lua` implementations.

**C-05: Unpublished review lifecycle.** Define start/resume, add/edit/delete pending
comments, publication, discard, cancellation, restart recovery, changed-head
behavior, and the interaction with server drafts created outside Neovim. Never
overwrite or publish unrelated existing server drafts implicitly. Decide whether
local draft persistence is part of the first delivery. Keep in-flight optimism
separate from remote unpublished state. Arcanum support requires its own contract
research; GitHub review semantics cannot simply be transplanted.
Atlas: GitHub `api/reviews.lua:with_pending`, `:create_pending`, `:submit`,
`api/comments.lua:publish_comment`; GitLab draft-note paths. Study
`spec/providers/github/pending_comment_spec.lua` alongside the implementation.

**C-06/C-07: Suggestions.** Atlas creates Markdown suggestion fences from selected
new-side lines and uses provider-specific GitLab range syntax. It recognizes
suggestion blocks for rendering. That is authoring/display, not automatic
application. For local application, preview a patch, verify the expected source,
reject ambiguity, support undo, and do not stage/commit automatically. Evaluate
multi-line, deleted, stale, overlapping, and already-applied suggestions.
Atlas: `lua/atlas/pulls/diff/comments.lua:add`,
`lua/atlas/pulls/ui/components/review_threads.lua:suggestion_content`.

**C-08: Composition helpers.** Atlas's conventional-comment templates are
configurable and can enter insert mode. Completion is provider-owned and accepts
review participants/context. Copy the extensible contract idea, not assumptions
that every author is mentionable or that completion cache identity is harmless.
Keep helpers optional and preserve source context/text if lookup fails.
Atlas: `lua/atlas/pulls/actions/review.lua:comment_template_action`,
`lua/atlas/ui/popups/editor/init.lua`, and
`lua/atlas/providers/{github,gitlab,bitbucket}/completion/author.lua`.

**C-09/C-10: Discovery and recovery.** Extend existing unresolved filtering rather
than adding a parallel filter path. Distinguish remote outdated, locally shifted,
locally changed, deleted, and unavailable anchors. Offer original revision,
best-current-match preview, or exact browser link where appropriate; never label
an approximation exact. Richer previews can include path, side, range, state,
author, context, and why a location cannot be opened.

**C-11/C-12: Integration boundaries.** Provide read-only queries for active review
identity, per-file/per-line/unresolved counts, and immutable discussion snapshots.
Define events for attachment/detachment, snapshot replacement, local remapping,
and pending/completed writes, with explicit unsubscribe/cleanup behavior. Adapter
code should consume this interface instead of provider internals. Test closing
viewers, switching files/tabs, changing revisions, and late async results.
Atlas: `lua/atlas/pulls/diff/codediff/`, `diff/diffview/`,
`diff/session.lua:review_attached`, `:detach`, and `lua/atlas/core/events.lua`.

**C-13: Local notes.** Atlas stores issue/suggestion/note/praise types separately
from remote comments and records context to flag stale notes. Storage is under
the data directory, supports `ATLAS_NOTES_DIR`, and uses temporary-file/rename
writes. Its target includes provider, host, repository, and PR. A CLI can add
notes consumed by the UI. This is not proof of safe concurrent read-modify-write
between editor and CLI; define that contract explicitly if adopted. Decide how
notes survive rebases, how users publish them deliberately, and whether automatic
deletion is ever appropriate.
Atlas: `lua/atlas/pulls/notes/{init,storage}.lua`, `lua/atlas/pulls/diff/notes.lua`,
and `bin/atlas-notes`.

**C-14/C-15/C-16/C-17: Optional extensions.** Keep reviewed-file state independent
of thread resolution. Copy only exact provider URLs and explain missing URLs.
An explicit PR selector must not reuse another checkout's mappings. New providers
should enter through registration/DI with capabilities for discussion kinds,
draft publication, reactions, and location validation. Atlas's generic feature
labels are insufficient specifications, particularly for Bitbucket publication.

## Stability evidence and validation limits

The following counts describe the complete repositories, not discussion-only
code and not coverage percentages. They include comments/annotations.

| Measure at research time | Parley | Atlas |
|---|---:|---:|
| Lua files under `lua/` | 113 | 344 |
| Lines under `lua/` | 16,988 | 79,095 |
| Spec files | 97 | 38 |
| Literal `it(...)` declarations | 1,191 | 239 |
| Test/support Lua lines | 24,578 | 5,060 |
| CI runtime | Headless Neovim 0.10 and nightly | Busted with mocked `vim` |
| Formatting checks run | Passed | Passed |
| Lint run | Luacheck passed | Selene unavailable |
| Generated help consistency | Passed | No equivalent check found |

All 601 Lua files across the source, plugin, and test directories parsed under
the installed Neovim runtime. Full suites were not run: Parley's expected
`.tests/plenary.nvim` was absent and Atlas's Busted runner was unavailable. No
dependencies were installed. Passing syntax/format/lint/docs checks does not
establish live compatibility or eliminate the behavioral findings above.

Parley has substantial tests for identity changes, pending snapshots, validation,
cancellation, periodic visibility, and actual Neovim windows/buffers. Atlas has
useful provider, mapper, pending-comment, Git/worktree, and selected UI tests,
but comparatively sparse coverage for its larger review UI surface. Its mocked
`vim.schedule()` runs callbacks immediately, so those tests alone cannot establish
real editor scheduling/race behavior. Both use mocked provider operations.

Parley's architectural policy tests are valuable structural checks, not semantic
proofs. The GitHub provider was 706 lines at research time, exceeding the stated
600-line maximum; several tests also exceeded it. Plan refactoring where affected,
without treating line counts or test volume as stability scores.

## How to build a plan from this reference

1. Reproduce P-01 through P-06 against the current checkout; turn concrete defects
   into regression tests before changes. Retain the distinctions between bugs,
   documented limits, missing UI, and audit leads.
2. Establish common anchor, identity, and write-outcome contracts. Extend existing
   abstractions rather than adding provider checks to core/UI modules.
3. Select a bounded discussion feature slice from C-03 through C-17. Avoid mixing
   new providers, a new diff viewer, and a server-draft lifecycle in one change.
4. For each slice, specify provider support, user entry points, text preservation,
   partial-success behavior, stale-context behavior, navigation, and documentation.
5. Validate with pure mapping/transport tests plus real Neovim integration tests;
   include failure paths and public command reachability, not only method existence.
6. Update `doc/parley.nvim.txt.in`, provider compatibility references, and existing
   TODO items when implementation changes user-facing behavior. Generate help via
   the documented tooling rather than editing generated help.
7. Keep live compatibility validation explicit and separate from mocked success.
   Any live writes need a deliberately selected test review/account and scope.

The likely first planning boundary is **GitHub discussion correctness and safety**
(P-01/P-02/P-03/P-04/P-06), followed by a deliberate choice between broader comment
kinds, unpublished review comments, or richer viewer integration. This ordering
is a recommendation, not authorization to implement every candidate.
