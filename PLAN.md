# Development Plan

Phase 1 target: GitHub provider, core UI (signs, virtual text, discussion float,
input subwindow), full read/write operations, line anchoring with staleness
warning, diffview.nvim integration, statusline component, disk cache.

---

## Layer 0: Core abstractions (no I/O, highly testable)

### Step 1 — Discussion data model

Define the normalized data types that all providers produce and all UI code
consumes. This is the central contract between providers and renderers.

Key types: `Thread`, `Comment`, `Reaction`, `ReviewStatus`, `PRInfo`. Must
support both flat (GitHub) and tree (Arcanum) threading from day one per
PROJECT.md §5.3. Pure data structures, no logic beyond helpers like
`Thread:is_resolved()`.

TDD: write spec first, validate type shapes and helpers.

### Step 2 — Provider interface

Define the abstract provider contract as a Lua module with method signatures:

- `detect_pr(repo_root, branch) -> PRInfo|nil`
- `fetch_threads(pr) -> Thread[]`
- `post_comment(pr, file, line, body)`
- `reply(pr, thread_id, body)`
- `resolve(pr, thread_id)` / `unresolve(pr, thread_id)`
- `react(pr, comment_id, reaction)`
- `edit(pr, comment_id, body)`
- `delete(pr, comment_id)`
- `submit_review(pr, event, body)`
- `auth() -> token`

No real implementation yet — just the interface shape and a mock provider for
testing.

### Step 3 — Provider registry

A small module that selects the right provider based on remote URL pattern
(e.g. `github.com` → GitHub provider). Wire it into `setup()`.

---

## Layer 1: VCS and buffer detection

### Step 4 — VCS detection

Detect whether the current buffer is inside a VCS repo and which VCS (git
first). Extract repo root, current branch, remote URL. Uses `vim.system`
(async-compatible).

### Step 5 — Buffer context detection

Classify current buffer: regular file | diffview diff | non-VCS | outside PR.
Per PROJECT.md §5.2, use only observable buffer properties (filetype, name).

---

## Layer 2: Network and caching

### Step 6 — HTTP client wrapper

Thin wrapper around `plenary.curl` that:

- Uses `plenary.async` exclusively (no sync calls)
- Injects auth headers from provider
- Handles rate-limit headers (track remaining, pause + retry)
- Returns structured results

### Step 7 — Disk cache

Cache API responses to `~/.cache/nvim/parley/` (XDG). Key by provider + PR +
endpoint. Serve stale data while background refresh runs. Invalidation on
explicit refresh or timer.

---

## Layer 3: GitHub provider (Phase 1 target)

### Step 8 — GitHub auth

Read token from `~/.config/gh/hosts.yml`. No custom credential storage.

### Step 9 — GitHub provider implementation

Implement the provider interface against GitHub REST API. PR detection from
branch, fetch review comments/threads, map to the discussion data model.

---

## Layer 4: Line anchoring

### Step 10 — Line anchoring engine

Map `(file, line-in-PR-diff)` to `(line-in-local-buffer)`. Use `git diff` or
similar to compute hunks and remap. Emit confidence/staleness warnings when
divergence is large.

---

## Layer 5: UI — read path

### Step 11 — Gutter signs + virtual text

Place extmarks on commented lines. Signs in the gutter, truncated first-comment
snippet as virtual text.

### Step 12 — Navigation keymaps

`]c` / `[c` to jump between commented lines.

### Step 13 — Discussion floating window

Floating window tied to cursor, showing the full thread for the current line.
Markdown rendering via `render-markdown.nvim`. `nui.nvim` for the float.

---

## Layer 6: UI — write path

### Step 14 — Input subwindow + reply / new comment

Multiline Markdown buffer for writing. Posts via provider, refreshes thread.

### Step 15 — Resolve/unresolve, reactions, edit/delete

---

## Layer 7: Integration and polish

### Step 16 — Autocommands and refresh

BufEnter trigger, configurable timer, explicit refresh command.

### Step 17 — Statusline component

Expose PR number, approval status, unresolved count.

### Step 18 — diffview.nvim integration

Detect diffview buffers, translate diff-buffer lines to real lines, apply
standard anchoring.

---

## Principles

- **TDD throughout** — each step starts with specs using the mock provider; no
  real API calls in tests.
- **Bottom-up** — data model and interfaces first so UI and providers are
  decoupled.
- **Abstractions designed for Phase 2+** — tree threading, provider registry,
  VCS abstraction all considered from Step 1.
- **Async from day one** — `plenary.async` in the HTTP layer; never synchronous
  I/O.
