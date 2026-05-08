--- parley.orchestrator — End-to-end refresh of PR signs for a buffer.
---
--- Glue layer that wires together every Step 1–12 module so opening a file
--- in a checked-out PR branch causes real GitHub discussions to appear as
--- gutter signs / virtual text.
---
--- Flow (all inside one plenary.async coroutine):
---   1. Classify the buffer (parley.buffer_context).
---   2. Resolve the provider from the VcsInfo (parley.registry).
---   3. Compute the repo-relative path; bail if outside the repo root.
---   4. Stale-while-revalidate render from disk cache (parley.cache + signs).
---   5. detect_pr → fetch_discussions → cache the responses.
---   6. anchor.map_discussions for the current file's discussions.
---   7. signs.render with the fresh data.
---
--- Errors in steps 5–7 are caught and surfaced via vim.notify; whatever step 4
--- already drew on screen is left in place per PROJECT.md §5.7 (silent
--- deactivation, fall back to cache).
---
--- A per-buffer in-flight guard prevents BufEnter storms (the same buffer
--- entered many times in quick succession) from queuing parallel fetches.

local async = require("plenary.async")
local anchor = require("parley.anchor")
local buffer_context = require("parley.buffer_context")
local cache = require("parley.cache")
local registry = require("parley.registry")
local signs = require("parley.signs")

local M = {}

-- ---------------------------------------------------------------------------
-- Module state
-- ---------------------------------------------------------------------------

--- Reentrancy guard: bufnr → true while a refresh is mid-flight.
--- Cleared in the surrounding pcall's success and failure paths.
--- @type table<integer, true>
M._in_flight = {}

--- Latest per-buffer discussion snapshot, used by the discussion window.
--- @type table<integer, {
---   discussions: parley.Discussion[],
---   mappings: table<string, parley.anchor.Mapping>,
---   pr: parley.PR|nil,
---   head_sha: string,
--- }>
M._buffer_state = {}

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Compute the repo-relative path of `abs_path` under `root`.
--- Returns nil when `abs_path` is not inside `root`.
---
--- @param abs_path string  Absolute file path
--- @param root     string  Absolute repo root (no trailing slash)
--- @return string|nil
local function relative_to_root(abs_path, root)
  -- Match exactly "<root>/" as a prefix.
  if abs_path:sub(1, #root + 1) == root .. "/" then
    return abs_path:sub(#root + 2)
  end
  return nil
end

--- Build the cache key for the per-branch PR record.
--- @param opts { host: string, owner: string, repo: string }
--- @param branch string
--- @return parley.CacheKey
local function pr_cache_key(opts, branch)
  return {
    provider = "github",
    repository = opts.owner .. "/" .. opts.repo,
    subkey = "pr_branch_" .. branch,
  }
end

--- Build the cache key for the per-PR discussion list.
--- @param opts { host: string, owner: string, repo: string }
--- @param pr_id string
--- @return parley.CacheKey
local function discussions_cache_key(opts, pr_id)
  return {
    provider = "github",
    repository = opts.owner .. "/" .. opts.repo,
    subkey = "discussions_" .. pr_id,
  }
end

--- Filter `discussions` to those anchored to `rel_path`.
--- @param discussions parley.Discussion[]
--- @param rel_path    string
--- @return parley.Discussion[]
local function filter_for_file(discussions, rel_path)
  local out = {}
  for _, d in ipairs(discussions) do
    if d.file == rel_path then
      table.insert(out, d)
    end
  end
  return out
end

--- Map and render the given file-scoped discussions onto `bufnr`.
--- A no-op when `discussions` is empty (still clears any prior signs so the
--- gutter is consistent with the data).
---
--- @param bufnr        integer
--- @param root         string
--- @param head_sha     string
--- @param file_discs   parley.Discussion[]
--- @param render_opts  { signs: parley.SignsConfig, virtual_text: parley.VirtualTextConfig }
local function map_and_render(bufnr, root, head_sha, file_discs, render_opts)
  if #file_discs == 0 then
    M._buffer_state[bufnr] = nil
    signs.clear(bufnr)
    return
  end
  local mappings = anchor.map_discussions(root, head_sha, file_discs)
  M._buffer_state[bufnr] = {
    discussions = file_discs,
    mappings = mappings,
    pr = nil,
    head_sha = head_sha,
  }
  signs.render(bufnr, file_discs, mappings, render_opts)
end

-- ---------------------------------------------------------------------------
-- Seams (replaceable in tests)
-- ---------------------------------------------------------------------------

--- Notify hook; replace in tests to capture warnings.
--- @type fun(msg: string, level: integer)
M._notify = function(msg, level)
  vim.notify(msg, level)
end

--- Config accessor; replace in tests to avoid pulling parley.init.config.
--- Returns the active parley.Config table.
--- @type fun(): parley.Config
M._get_config = function()
  return require("parley").config
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Return the latest discussion snapshot for `bufnr`, or nil.
--- @param bufnr integer
--- @return {
---   discussions: parley.Discussion[],
---   mappings: table<string, parley.anchor.Mapping>,
---   pr: parley.PR|nil,
---   head_sha: string,
--- }|nil
function M.get_buffer_state(bufnr)
  return M._buffer_state[bufnr]
end

--- Clear the latest discussion snapshot for `bufnr`.
--- @param bufnr integer
function M.clear_buffer_state(bufnr)
  M._buffer_state[bufnr] = nil
end

--- Refresh signs for `bufnr` from the configured provider.
---
--- Must be called inside a plenary.async coroutine.  Use M.refresh_async
--- from sync call sites (autocmds, user commands).
---
--- @param bufnr integer
--- @param opts? { force?: boolean }  force=true bypasses the stale render shortcut
function M.refresh(bufnr, opts)
  opts = opts or {}

  if M._in_flight[bufnr] then
    return
  end

  local ctx = buffer_context.classify(bufnr)
  if ctx.kind ~= "regular" then
    return
  end

  -- registry.resolve uses spec.detect(vcs_info) → opts; we need both the
  -- opts (for cache keys) and the provider instance.  Iterate registered
  -- specs ourselves so we can capture the opts.
  local provider_opts = nil
  local provider = nil
  for _, spec in ipairs(registry.registered()) do
    local p_opts = spec.detect(ctx.vcs_info)
    if p_opts ~= nil then
      provider_opts = p_opts
      provider = spec.factory(p_opts)
      break
    end
  end
  if not provider or not provider_opts then
    return
  end

  local rel_path = relative_to_root(ctx.path, ctx.vcs_info.root)
  if not rel_path then
    return
  end

  local branch = ctx.vcs_info.branch
  if not branch or branch == "" then
    -- Detached HEAD or unknown branch: cannot map to a PR.
    return
  end

  local config = M._get_config()
  local render_opts = { signs = config.signs, virtual_text = config.virtual_text }

  -- ── Step 4: stale-while-revalidate render ────────────────────────────────
  if not opts.force then
    local pr_entry = cache.get(pr_cache_key(provider_opts, branch))
    if pr_entry and pr_entry.data and pr_entry.data.id then
      local disc_entry = cache.get(discussions_cache_key(provider_opts, pr_entry.data.id))
      if disc_entry and disc_entry.data then
        local stale_head_sha = pr_entry.data.head_sha or ""
        local file_discs = filter_for_file(disc_entry.data, rel_path)
        if stale_head_sha ~= "" then
          pcall(map_and_render, bufnr, ctx.vcs_info.root, stale_head_sha, file_discs, render_opts)
        end
      end
    end
  end

  -- ── Steps 5–7: fetch fresh data and re-render ────────────────────────────
  M._in_flight[bufnr] = true
  local ok, err = pcall(function()
    local pr = provider:detect_pr(ctx.vcs_info.root, branch)

    if pr == nil then
      -- No open PR for this branch: silently deactivate.
      M.clear_buffer_state(bufnr)
      signs.clear(bufnr)
      cache.invalidate(pr_cache_key(provider_opts, branch))
      return
    end

    local head_sha = (provider.head_sha and provider:head_sha(pr)) or ""

    -- Cache the PR record (with head_sha embedded so stale renders work).
    cache.set(pr_cache_key(provider_opts, branch), {
      id = pr.id,
      head_sha = head_sha,
    })

    local discussions = provider:fetch_discussions(pr)
    cache.set(discussions_cache_key(provider_opts, pr.id), discussions)

    local file_discs = filter_for_file(discussions, rel_path)
    map_and_render(bufnr, ctx.vcs_info.root, head_sha, file_discs, render_opts)
    local state = M._buffer_state[bufnr]
    if state then
      state.pr = pr
    end
  end)
  M._in_flight[bufnr] = nil

  if not ok then
    M._notify("parley: refresh failed: " .. tostring(err), vim.log.levels.WARN)
  end
end

--- Sync-callable wrapper around M.refresh.  Use from autocmds / user commands.
---
--- @param bufnr integer
--- @param opts? { force?: boolean }
function M.refresh_async(bufnr, opts)
  async.run(function()
    M.refresh(bufnr, opts)
  end)
end

return M
