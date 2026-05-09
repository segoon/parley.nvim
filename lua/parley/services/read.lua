--- parley.services.read — read-side rendering wrapper over repositories.

local async_operation = require("parley.async_operation")
local context_repository = require("parley.repositories.context")
local provider_repository = require("parley.repositories.provider")
local review_repository = require("parley.repositories.review")
local signs = require("parley.signs")

local M = {}
M._subscriptions = {}

--- @type fun(msg: string, level: integer): nil
M._notify = function(msg, level)
  vim.notify(msg, level)
end

--- @type fun(): parley.Config
M._get_config = function()
  return require("parley").config
end

--- @param bufnr integer
--- @param snapshot table|nil
local function render_snapshot(bufnr, snapshot)
  if not snapshot or not snapshot.discussions or #snapshot.discussions == 0 then
    signs.clear(bufnr)
    return
  end

  local config = M._get_config()
  signs.render(bufnr, snapshot.discussions, snapshot.mappings or {}, {
    signs = config.signs,
    virtual_text = config.virtual_text,
  })
end

local function ensure_subscription(bufnr)
  if M._subscriptions[bufnr] then
    return
  end
  M._subscriptions[bufnr] = review_repository.subscribe(bufnr, function(snapshot)
    render_snapshot(bufnr, snapshot)
  end)
end

--- Perform the blocking review refresh for bufnr.
--- Must be called from within a plenary.async coroutine.
--- @param bufnr integer
--- @param opts { force?: boolean, notify_errors?: boolean }
--- @return table|nil
local function do_refresh(bufnr, opts)
  ensure_subscription(bufnr)
  local snapshot = review_repository.refresh(bufnr, opts)
  if snapshot and snapshot.status == "error" and opts.notify_errors ~= false and snapshot.error then
    M._notify("parley: refresh failed: " .. tostring(snapshot.error), vim.log.levels.WARN)
  end
  return snapshot
end

--- @param bufnr integer
--- @return table|nil
function M.get_buffer_state(bufnr)
  local snapshot = review_repository.get(bufnr)
  if not snapshot then
    return nil
  end
  local provider_snapshot = provider_repository.get(bufnr)
  local context_snapshot = context_repository.get(bufnr)
  snapshot.provider = provider_snapshot and provider_snapshot.provider or nil
  snapshot.vcs_info = context_snapshot and context_snapshot.vcs_info or nil
  snapshot.rel_path = context_snapshot and context_snapshot.rel_path or nil
  return snapshot
end

--- @param bufnr integer
--- @param opts? { scope?: 'file'|'all' }
--- @return parley.Discussion[]
function M.list_discussions(bufnr, opts)
  opts = opts or {}
  local snapshot = review_repository.get(bufnr)
  if not snapshot then
    return {}
  end
  if opts.scope == "all" then
    return vim.deepcopy(snapshot.all_discussions or {})
  end
  return vim.deepcopy(snapshot.discussions or {})
end

--- @param bufnr integer
function M.clear_buffer_state(bufnr)
  if M._subscriptions[bufnr] then
    M._subscriptions[bufnr]()
    M._subscriptions[bufnr] = nil
  end
  review_repository.invalidate(bufnr)
  provider_repository.invalidate(bufnr)
  context_repository.invalidate(bufnr)
  signs.clear(bufnr)
end

--- Start an async refresh for bufnr.
---
--- A progress popup is shown when:
---   - opts.progress is true (e.g. explicit :Parley refresh), OR
---   - there is no existing in-memory snapshot yet (first-time / cold cache).
---
--- The popup is suppressed (silent) when a snapshot already exists because the
--- stale data is rendered immediately while the background fetch completes.
---
--- context_repository.refresh and provider_repository.refresh are called
--- synchronously before the async coroutine is spawned so that the `silent`
--- decision is made with up-to-date context. do_refresh re-checks context
--- inside the coroutine to guard against state changes during scheduling.
---
--- @param bufnr integer
--- @param opts? { force?: boolean, notify_errors?: boolean, progress?: boolean }
--- @param callback? fun(snapshot: table|nil): nil
function M.refresh_async(bufnr, opts, callback)
  opts = opts or {}

  -- Fast sync pre-check: context/provider detection is in-memory plus branch
  -- detection; no network or disk I/O. Required before spawning the coroutine
  -- so the `silent` flag can be set correctly.
  local ctx = context_repository.refresh(bufnr)
  if not ctx or ctx.kind ~= "regular" or not ctx.rel_path then
    return
  end
  if not ctx.vcs_info or not ctx.vcs_info.branch or ctx.vcs_info.branch == "" then
    return
  end
  if not provider_repository.refresh(bufnr) then
    return
  end

  local has_snapshot = review_repository.get(bufnr) ~= nil
  local silent = not opts.progress and has_snapshot

  -- Capture the snapshot in a closure so the callback always receives it even
  -- when fn throws due to an error snapshot (fn's return value is lost on throw).
  local last_snapshot = nil

  async_operation
    .new({
      bufnr = bufnr,
      silent = silent,
      fn = function()
        local snapshot = do_refresh(bufnr, opts)
        last_snapshot = snapshot
        if snapshot and snapshot.status == "error" then
          error(snapshot.error or "refresh failed")
        end
        return snapshot
      end,
      popup = silent and nil or {
        progress = "Refreshing discussions",
        success = "Refresh complete",
        error = "Refresh failed",
      },
      finally_scheduled_fn = callback and function(_ok, _result)
        callback(last_snapshot)
      end or nil,
    })
    :start()
end

return M
