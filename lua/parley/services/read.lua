--- parley.services.read — read-side rendering wrapper over repositories.

local async = require("plenary.async")
local async_operation = require("parley.async_operation")
local context_repository = require("parley.repositories.context")
local provider_repository = require("parley.repositories.provider")
local review_repository = require("parley.repositories.review")
local signs = require("parley.signs")

local M = {}
M._subscriptions = {}
--- @type table<integer, integer> Active read counts, including preparation.
M._active = {}
--- @param bufnr integer
--- @return boolean
function M.is_refreshing(bufnr)
  return (M._active[bufnr] or 0) > 0
end

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
  local window = package.loaded["parley.discussion_window"]
  if window and window.refresh_snapshot then
    window.refresh_snapshot(bufnr, snapshot)
  end
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
--- @param opts table
--- @return table|nil
local function do_refresh(bufnr, opts)
  ensure_subscription(bufnr)
  local snapshot = review_repository.refresh(bufnr, opts)
  if
    snapshot
    and snapshot.status == "error"
    and not opts.background
    and opts.notify_errors ~= false
    and snapshot.error
  then
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
  snapshot.provider_display_name = snapshot.provider and snapshot.provider.display_name or nil
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
  review_repository.detach(bufnr)
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
--- Phase 1 (detection coroutine): context_repository.refresh and
--- provider_repository.refresh run inside an async coroutine so that VCS git
--- subprocess calls (vcs._vcs_detect → await.system) can yield safely. This
--- avoids the "attempt to yield across C-call boundary" error when called from
--- a BufEnter autocmd.
---
--- Phase 2 (fetch operation): AsyncOperation is created with the `silent` flag
--- determined in Phase 1 and started from within the detection coroutine,
--- which schedules its own coroutine for the actual network work.
---
--- @param bufnr integer
--- Completion occurs exactly once, including early exits and preparation errors.
--- @param opts? { force?: boolean, notify_errors?: boolean, progress?: boolean,
--- background?: boolean, expected_key?: string }
--- @param callback? fun(snapshot: table|nil): nil
function M.refresh_async(bufnr, opts, callback)
  opts = vim.tbl_extend("force", {}, opts or {})
  if opts.background then
    opts.force, opts.notify_errors = true, false
    local activity = review_repository.activity(bufnr)
    local provider = provider_repository.get(bufnr)
    local context = context_repository.get(bufnr)
    opts.expected_temporary = provider and provider.persistent == false
    opts.expected_vcs_info = context and context.vcs_info
    opts.expected_key = opts.expected_key or (activity and activity.key)
  end
  local completed = false
  M._active[bufnr] = (M._active[bufnr] or 0) + 1
  local function finish(snapshot)
    if completed then
      return
    end
    completed = true
    local count = (M._active[bufnr] or 1) - 1
    M._active[bufnr] = count > 0 and count or nil
    if callback then
      vim.schedule(function()
        callback(snapshot)
      end)
    end
  end

  -- Phase 1: silent detection. VCS git subprocesses require a coroutine context;
  -- this wrapper provides it without showing any popup.
  async.run(function()
    local ok, err = pcall(function()
      local ctx = context_repository.refresh(bufnr)
      if not ctx or ctx.kind ~= "regular" or not ctx.rel_path then
        M.clear_buffer_state(bufnr)
        finish(nil)
        return
      end
      if not ctx.vcs_info or not ctx.vcs_info.branch or ctx.vcs_info.branch == "" then
        M.clear_buffer_state(bufnr)
        finish(nil)
        return
      end
      local resolved, provider_result = pcall(provider_repository.refresh, bufnr)
      if not resolved or not provider_result then
        if not resolved and opts.notify_errors ~= false then
          M._notify("Provider identity or construction failed", vim.log.levels.WARN)
        end
        M.clear_buffer_state(bufnr)
        finish(nil)
        return
      end

      local provider_snapshot = provider_repository.get(bufnr)
      local review_key = review_repository.make_key(provider_snapshot, ctx)
      if not review_repository.get(bufnr) then
        signs.clear(bufnr)
      end
      local has_data = review_key and review_repository.has_review(review_key) or false
      if not opts.background and not has_data and review_key then
        has_data = review_repository.has_cached_review(provider_snapshot, ctx.vcs_info.branch)
      end
      local silent = opts.background or not opts.progress and has_data

      -- Capture the snapshot in a closure so the callback always receives it even
      -- when fn throws due to an error snapshot (fn's return value is lost on throw).
      local last_snapshot = nil

      -- Phase 2: start the fetch operation. Called from within the Phase 1
      -- coroutine: start() shows the popup synchronously (queued via vim.schedule)
      -- then schedules a new coroutine for the network work.
      async_operation
        .new({
          bufnr = bufnr,
          silent = silent,
          fn = function()
            local snapshot = do_refresh(bufnr, opts)
            last_snapshot = snapshot
            if snapshot and snapshot.status == "error" then
              error(snapshot.error or "refresh failed", 0)
            end
            return snapshot
          end,
          popup = not silent
              and {
                progress = "Refreshing discussions (" .. provider_snapshot.provider:progress_label() .. ")...",
                success = "Refresh complete",
                error = "Refresh failed",
              }
            or nil,
          finally_scheduled_fn = function(_ok, _result)
            finish(last_snapshot)
          end,
        })
        :start()
    end)
    if not ok then
      if opts.notify_errors ~= false then
        M._notify("parley: refresh failed: " .. tostring(err), vim.log.levels.WARN)
      end
      finish(nil)
    end
  end)
end

return M
