# parley.nvim

A Neovim plugin for inline PR discussion — read, write, and navigate code review
comments without leaving the editor. Works in regular file buffers and inside
diffview.nvim.

---

## 1. Problem Statement

Developers working on PRs constantly switch between the browser and Neovim to read
review comments, respond to discussions, and track unresolved threads. Existing
plugins (octo.nvim, gh.nvim) are GitHub-centric general-purpose UIs for the whole
GitHub feature surface — they don't solve the core problem of **tightly integrating
PR discussion directly into the code editing experience** at the line level, across
multiple hosting providers.

---

## 2. Solution Overview

A Neovim plugin written in Lua that:
- Fetches PR data from a hosting provider via REST API
- Anchors review comments to specific lines in the local buffer
- Visualizes comment presence inline using gutter signs and virtual text
- Provides a floating discussion window tied to the cursor position
- Supports full read/write interaction with the PR discussion without leaving Neovim
- Works both in regular file buffers and inside diffview.nvim diff buffers

---

## 3. Target Users

- **Software engineers** actively participating in code review — both as authors
  responding to feedback and as reviewers leaving comments
- Expected to be comfortable with Neovim and keyboard-driven workflows
- May work across different hosting platforms (GitHub, GitLab, Gitbucket, Yandex
  Arcanum, Perforce-based review systems, etc.)
- Single user group with uniform expertise level; no simplified or
  accessibility-oriented UI needed

---

## 4. User Scenarios

### 4.1 Reviewing a PR in a regular buffer (reading)

1. User opens a file from a local working copy. The plugin detects the current branch
   and maps it to an open PR on the configured provider.
2. Gutter signs appear on lines that have review comments. Virtual text at the end of
   those lines shows a truncated snippet of the first comment.
3. User navigates between commented lines using `]c` / `[c`.
4. User places cursor on a commented line; the discussion floating window opens
   showing the full flat/tree thread for that line.
5. User reads Markdown-rendered comments, sees reactions, sees resolved/unresolved
   state.

### 4.2 Reviewing a PR in diffview.nvim

1. User opens diffview.nvim for the current branch. The plugin auto-detects the
   diffview diff buffers by filetype/buffer name.
2. Gutter signs and virtual text appear on the **new file side** (right pane) of the
   diff, on lines that have review comments. Line numbers are translated from
   diff-buffer positions to real file lines transparently.
3. Navigation (`]c` / `[c`), discussion float, and all interaction work identically
   to the regular buffer experience.
4. The discussion floating window appears as an overlay on top of the diffview layout
   (not embedded in it).

### 4.3 Responding to a comment

1. User opens the discussion floating window (cursor on a commented line, in either
   regular buffer or diffview).
2. User navigates the thread with arrow keys, selects a specific thread with Enter.
3. Input subwindow opens (multiline Markdown buffer). User types a reply and submits.
4. Plugin posts the reply via REST API, refreshes the thread in the window.

### 4.4 Leaving a new line-level comment

1. User selects a line range in the buffer (visual selection) — works in both regular
   buffer and diffview new-side pane.
2. User triggers a keymap to open the input subwindow for a new top-level comment on
   that range.
3. In a diffview buffer, the plugin translates the selected diff-buffer line range to
   real file line numbers before posting.
4. User writes the comment (Markdown) and submits. Plugin posts it and anchors it to
   the selected lines.

### 4.5 Resolving a thread

1. User runs `:Parley discussion resolve` or `:Parley discussion reopen` for the
   selected Arcanum issue, or chooses a thread at the source cursor.
2. Plugin checks provider capability and open/resolved state, updates the root
   issue, then refreshes the view and unresolved count without discarding drafts.
3. General and unavailable-location threads support the same actions. Unsupported
   providers and incomplete threads explain why the action cannot proceed.
   GitHub resolution remains planned; no default resolution keymaps are assigned.

### 4.6 Reacting to a comment

1. From the discussion window, user triggers a keymap to add/remove a reaction on a
   comment.
2. Plugin sends the reaction toggle request and updates the displayed reactions.

### 4.7 Editing / deleting own comments

1. From the discussion window, user selects their own comment and triggers edit or
   delete keymap.
2. For edit: the input subwindow opens prefilled with the existing content; on
   submit, plugin sends a PATCH/PUT request.
3. For delete: confirmation prompt, then DELETE request.

### 4.8 PR-level review actions

1. User runs `:Parley review actions` to select an explicit provider action.
2. Arcanum offers normal/sticky ship, unship, block merge, and unblock merge.
   Confirmation shows the PR, loaded revision, and current verdict. Sticky approval
   includes future diffs. No review message is silently discarded.
3. The provider rechecks the active diff before submission; the API still has a
   race between recheck and mutation. Selected discussions and drafts survive refresh.
4. Actual reviewer verdicts and remaining approval requirements determine status.
   Failed status reads produce unknown while discussions remain usable.

### 4.9 PR status awareness

1. Statusline component shows: `PR #42 · ✓ approved · 3 unresolved` (or similar).
2. Data refreshes on buffer enter, on a configurable timer, and on explicit user
   command.

---

## 5. Core Requirements

### 5.1 Line anchoring

- Comments are anchored to lines by diffing the file at the PR base revision against
  the local buffer content, then remapping line numbers through the diff hunks.
- When the local file is stale or heavily diverged, the plugin shows a **visual
  warning** (e.g., a different sign color or `vim.notify` message) but still
  attempts best-effort placement.
- The anchoring model must be **VCS-agnostic** at the interface level — providers
  supply a (file, line) pair and the plugin handles remapping.
- In diffview.nvim buffers, an **additional translation layer** maps diff-buffer
  line numbers to real file line numbers (new side only) before applying the
  standard anchoring logic. This keeps the anchoring core unaware of diffview
  internals.

### 5.2 Buffer context detection

The plugin must robustly detect the context of the current buffer to apply the
correct behavior:

| Context | Detection method |
|---|---|
| Regular file buffer | Standard filetype + file path inside a VCS repo |
| diffview.nvim diff buffer | Buffer filetype (`DiffviewFiles`, `DiffviewDiff` etc.) and/or buffer name pattern |
| Non-VCS buffer | No recognized repo root → plugin fully inactive |
| Outside any PR branch | Branch not mapped to an open PR → plugin fully inactive |

Detection must not rely on diffview.nvim internals — only on observable buffer
properties (filetype, name, options). This ensures the integration remains robust
across diffview.nvim version changes.

### 5.3 Provider abstraction

- A **provider interface** (Lua module contract) must be defined, covering: auth,
  PR detection from current branch, fetching comments/reactions/status, and all
  write operations.
- GitHub is the first implementation. GitLab, Gitbucket, Yandex Arcanum, and
  Perforce-based systems are planned future providers.
- The **discussion data model** must support both flat (GitHub-style) and
  arbitrarily deep tree (Arcanum-style) thread structures. The renderer must be
  generic enough to handle both.

### 5.4 Authentication

Arcanum resolves explicit token values and paths before its default token file.
Before loading a review or restoring its cache, it verifies the OAuth account;
only that account determines comment ownership. Verification failure stops loading.
Local Arc login remains diagnostic metadata. Health checks make no HTTP requests.
Arcanum discovery follows prefix-search pages until it finds the exact remote
branch, and stays inactive when no remote branch is configured.

- Secrets are read from standard credential files used by existing CLI tools
  (e.g., `~/.config/gh/hosts.yml` for GitHub, similar conventions for other
  providers).
- No custom credential storage.

### 5.5 Rate limiting and caching

- All API responses are **cached to disk** (survives Neovim restarts). Cache
  location follows XDG conventions (`~/.cache/nvim/parley/`).
- The plugin tracks rate limit headers and **silently pauses** requests when the
  limit is approached, retrying automatically when the window resets.
- No aggressive polling — refresh triggers are: buffer enter, a configurable timer
  (default 5 min), and explicit user command.

### 5.6 Performance

- All network calls are **fully async** (non-blocking) using `plenary.async`.
- The UI must remain responsive during fetches; stale cached data is shown while
  fresh data loads in the background.

### 5.7 Reliability

- If the plugin cannot detect a PR for the current branch, it **silently
  deactivates** — no errors, no UI noise.
- Network errors and API failures are reported via `vim.notify` at warn/error level,
  then the plugin falls back to cached data.

### 5.8 VCS scope

- Plugin is **active only inside a recognized VCS repository** (git, hg, Perforce,
  etc.). Outside any repo = fully inactive.
- Branch-to-PR mapping is provider-specific; the provider module is responsible for
  implementing it.

---

## 6. UI Specification

| Element | Behavior |
|---|---|
| **Gutter sign** | Appears on every line with ≥1 comment. Indicates presence only (no count, no state). Works in both regular buffers and diffview new-side pane. |
| **Virtual text** | Virtual lines below the commented line showing `author · timestamp`, the multiline first comment body, and, when applicable, a compact remaining-comment summary. |
| **Discussion float** | Opens tied to cursor position; stays open until explicitly closed. Follows cursor to new lines on move. Rendered as overlay in both regular buffer and diffview contexts. |
| **Thread rendering** | Flat list for GitHub; generic tree renderer for providers with nested replies. Markdown rendered via `render-markdown.nvim`. |
| **Input subwindow** | Multiline Markdown buffer within or adjacent to the discussion float. Opens for: new reply, new top-level comment, edit existing. |
| **Navigation** | `]c` / `[c` jump to next/prev commented line. Arrows + Enter to select threads in float. |
| **Statusline** | Component exposing: PR number, approval status, unresolved comment count. Compatible with lualine and vanilla statusline. |

---

## 7. Write Operations

All write operations are supported in both regular buffer and diffview contexts:

- Post a new line-level comment (from visual selection in buffer)
- Post a reply to a specific thread (from discussion window)
- Edit own comment
- Delete own comment
- Resolve / unresolve a thread
- Add / remove a reaction on a comment
- Submit a PR-level review (approve / request changes / comment)

---

## 8. Technology Stack

| Concern | Choice | Rationale |
|---|---|---|
| Language | Lua | Neovim native |
| Minimum Neovim | 0.10 | `vim.system`, `vim.iter`, modern extmark API |
| HTTP | `plenary.curl` | Widely used, no binary dependency beyond curl |
| Async | `plenary.async` | Established, widely used in the plugin ecosystem |
| UI components | `nui.nvim` | Handles floating windows, layouts, input boxes |
| Markdown rendering | `render-markdown.nvim` | Renders Markdown in Neovim buffers inline |
| Inline anchoring | `vim.api` extmarks | Native mechanism for signs, virtual text, highlights |
| diffview integration | Auto-detection via buffer filetype/name | Robust against diffview.nvim internal changes |
| Testing | `plenary.nvim` test harness + mocked providers | No real API calls in tests |
| Distribution | lazy.nvim-first, any plugin manager supported | Standard `setup({})` entry point |
| Config | `setup({})` Lua call | Modern Neovim plugin convention |
| Credentials | Provider-specific standard files | No custom secret storage |
| Cache | Disk, XDG path (`~/.cache/nvim/parley/`) | Survives restarts, reduces API pressure |

---

## 10. Open Risks

| Risk | Notes |
|---|---|
| Line re-anchoring reliability | Heuristic degrades with large uncommitted local changes. Show a non-intrusive warning when confidence is low. |
| diffview line translation | Diff buffers interleave old/new lines with decorations. Mapping diff-buffer line N to real file line M requires a dedicated, well-tested translation module. |
| diffview float placement | A floating overlay may obscure diff content. Consider user-configurable float position (top/bottom/right edge preference). |
| Non-git VCS branch detection | Each VCS needs its own detection logic (`hg branch`, `p4 info`, etc.). Must be part of the provider contract. |
| Arcanum API availability | Proprietary API; documentation may require internal access or reverse engineering. |
| Follow-cursor float UX | Continuously updating the float on cursor move may feel jarring. Apply a small debounce delay. |
| Plenary as hard dependency | Large library; worth revisiting if the plugin gains traction and minimizing deps becomes a priority. |
