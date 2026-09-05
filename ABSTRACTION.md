# Provider abstraction status

Updated: 2026-09-05. Original audit: 2026-09-04; re-audit baseline: `b92f78c`.
Historical findings, probe transcripts, and implementation rationale remain in
Git history. This document tracks current boundaries and remaining work.

All concrete provider code and data must live under `lua/parley/providers/`.
Shared workflows consume public contracts, registered implementations, and
provider-supplied metadata. The production inventory contains 77 Lua files:
50 shared files and 27 provider-owned files.

## Current boundaries

| Area | Shared responsibility | Provider-owned responsibility |
| --- | --- | --- |
| Setup/detection | Configuration merge, registries, buffer/context lifecycle | Defaults, factories, initialization, detectors |
| Reviews/cache | Contract validation, identity scoping, snapshots, projections | Identity derivation and normalized review/discussion data |
| Local writes | Revision dispatch, local safety, composer/progress lifecycle | VCS commands/status parsing, target eligibility, mutations |
| Presentation/health | Render public metadata and report diagnostics | Labels, reactions, tool/credential diagnostics |

Shared setup's import of `parley.providers` is the sole direct shared import into
the provider directory. Provider repositories construct instances through the
validated registry. Shared services call injected provider methods and registered
VCS adapters; concrete implementations may use shared infrastructure.

```mermaid
flowchart LR
    Setup[Shared setup] --> Catalog[Provider catalog]
    Catalog --> Registry[Shared registries]
    Catalog --> Providers[Concrete providers and VCS adapters]
    Workflows[Shared services and repositories] --> Registry
    Workflows -. injected contracts .-> Providers
    UI[Presentation] --> Workflows
```

The diagram summarizes composition and delegation, not every module import.
Normalized review states, opaque identifiers, Markdown composition, and common
clean-file protections are intentional shared concepts, not provider leaks.

## Remaining work

### R1. Shared diff reads still supply a concrete revision alias

**Status: open. Severity: 4/10. Category: residual VCS policy leak.**

[`vcs.read_diff()`](lua/parley/vcs.lua#L201) passes `head_sha or "HEAD"` to the
registered adapter. Its optional revision argument therefore adopts Git/Arc's
current-revision spelling on behalf of every VCS. A custom adapter that uses a
different revision syntax receives the wrong value unless it compensates for
shared behavior. The failure is on omitted-revision calls; built-in eligibility
normally supplies an explicit review revision.

**Executed probe:** register a custom adapter whose `diff` function records its
second argument, replace `vcs._runner` with an in-memory successful result, and
call `read_diff(info, "base", "file")`. Output: `implicit revision=HEAD`. No VCS
process was executed. The existing
[custom-adapter test](tests/parley/vcs_adapters_spec.lua) passes `"rev"` explicitly,
so its custom identifier does not test this default.

**Recommendation:** require an explicit revision for shared review diff reads,
reject absent/empty revisions before invoking adapters, and keep any
current-checkout convenience inside provider-owned adapters. Audit direct callers
and document the signature change. This keeps review operations tied to a known
revision and removes shared knowledge of a revision alias.

**Alternative:** preserve an optional revision and pass an explicit absence or
semantic operation to the adapter, letting each adapter resolve its own current
revision. This retains convenience but expands the adapter contract and allows
mutable-checkout diffs; it needs separate semantics and tests.

**Requirements/limits:** retain current built-in review behavior and error
handling. Leading-hyphen rejection in shared revision/base validation also embeds
CLI argument-safety assumptions; assess it alongside adapter input validation,
but do not remove protections without safe command construction. No incompatible
built-in revision was demonstrated by this audit.

**Complexity/maintenance:** small implementation and caller migration; low ongoing
cost for an explicit-revision contract, higher for dual current/immutable modes.
**Regression coverage:** a custom adapter with no `HEAD` alias; missing revision;
explicit opaque revision; unchanged built-in diff commands and failures.

### Integrated custom-provider regression

**Status: recommended; not implemented as one integrated workflow.**

Existing tests exercise custom VCS dispatch, metadata, reaction codes, identity,
configuration snapshots, and eligibility separately. Add one workflow with a
provider and VCS deliberately unlike the built-ins: custom detection, opaque
identity/revision/reaction values, display metadata, caching, reactions, and
posting without private GitHub-style fields. Keep real subprocesses and network
requests stubbed while using the actual shared orchestration.

Implement R1 first, then this integration coverage. The command-oriented VCS
adapter is an explicit current contract; arbitrary non-CLI VCS support remains
an extensibility consideration rather than a demonstrated regression.

## Resolved work

| Finding | Current behavior / defense |
| --- | --- |
| Concrete VCS implementations | Git/Arc commands and status parsers live under providers; generic adapters dispatch them. |
| Provider-specific health checks | Shared health uses registered diagnostics for the detected provider. |
| Reaction vocabulary | Choices and presentation come from optional provider hooks. |
| Cache identity | Required public identity scopes persistence; shared code reads no provider-private cache fields. |
| Setup/defaults and Arcanum host | Provider catalog owns composition and defaults; factories bind configuration snapshots and forward the host. |
| Statusline branding | Required `display_name` flows through buffer state; no URL inference. |
| Comment eligibility | Required provider validation runs before opening and posting; shared safety checks remain enforced. |
| Construction validation | Repository resolution uses the validated registry before identity resolution. |
| Architecture-policy coverage | Filesystem discovery covers all production modules; provider-layer and static-import checks reject boundary violations. |
| R3: immediate write completion | One lifecycle registers operations before starting, completes once, handles failures, and binds cancellation to the original operation. |
| R2: optional execution contract | Cancellable hooks and callback/handle types are declared; all present optional methods must be functions. Coroutine fallbacks remain available. |

R2 adds `begin_post_top_level_comment` and `begin_reply` to the declared optional
contract alongside reaction hooks. `parley.WriteResult`, `parley.WriteCallback`,
and `parley.CancelHandle` describe execution without imposing deferred callbacks.
The R3 runtime guards still validate outcomes/handles and preserve drafts on
failures; registry validation checks method presence and types, not execution.
See the [provider interface](lua/parley/provider.lua),
[write lifecycle](lua/parley/services/write_operation.lua), and
[custom-provider help template](doc/parley.nvim.txt.in).

## Verification and limits

Current regression coverage includes optional-method validation through the
registry, posting/replies with and without cancellable starters, callback timing,
cancellation, draft retention, provider metadata, configuration, and VCS dispatch.
See [contract tests](tests/parley/provider_spec.lua),
[write workflow tests](tests/parley/services/write_spec.lua),
[lifecycle tests](tests/parley/services/write_operation_spec.lua), and
[architecture checker tests](tests/parley/policy_checker_spec.lua).

Validation for this change: **909 tests pass**, with clean formatting and lint
checks.
No live provider API requests are needed for this refactor. The original audit
probes used injected dependencies; R1's omitted-revision result remains open.
Structural checks cover supported static imports, not copied algorithms or
arbitrary runtime indirection. Passing them does not establish semantic provider
independence; the integrated custom-provider scenario remains useful.
