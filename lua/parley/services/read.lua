--- parley.services.read — read-side rendering wrapper over repositories.

local async = require("plenary.async")
local context_repository = require("parley.repositories.context")
local provider_repository = require("parley.repositories.provider")
local review_repository = require("parley.repositories.review")
local signs = require("parley.signs")
local progress_ui_state = require("parley.ui_states.progress")

local M = {}
M._subscriptions = {}
M._next_progress_id = 0

M._notify = function(msg, level)
  vim.notify(msg, level)
end

M._get_config = function()
  return require("parley").config
end

M._defer = function(cb, timeout)
  vim.defer_fn(cb, timeout)
end

M._now = function()
  return math.floor((vim.uv or vim.loop).hrtime() / 1000000)
end

---@param state 'success'|'failed'|'cancelled'
---@return integer
local function progress_timeout(state)
  local config = M._get_config() or {}
  local progress = config.progress or {}
  if state == "success" then
    return progress.success_timeout or 1200
  end
  if state == "failed" then
    return progress.failed_timeout or 2500
  end
  return progress.cancelled_timeout or 1200
end

---@param bufnr integer
---@param message string
---@return { id: string, started_at: integer, title: string }
local function start_progress(bufnr, message)
  M._next_progress_id = M._next_progress_id + 1
  local now = M._now()
  local entry = {
    id = "read-" .. tostring(M._next_progress_id),
    bufnr = bufnr,
    title = "Parley",
    message = message,
    kind = "refresh",
    state = "running",
    started_at = now,
    updated_at = now,
  }
  progress_ui_state.upsert(entry)
  return {
    id = entry.id,
    started_at = entry.started_at,
    title = entry.title,
  }
end

---@param progress { id: string, started_at: integer, title: string }
---@param bufnr integer
---@param state 'success'|'failed'|'cancelled'
---@param message string
local function finish_progress(progress, bufnr, state, message)
  progress_ui_state.upsert({
    id = progress.id,
    bufnr = bufnr,
    title = progress.title,
    message = message,
    kind = "refresh",
    state = state,
    started_at = progress.started_at,
    updated_at = M._now(),
  })
  M._defer(function()
    progress_ui_state.remove(progress.id)
  end, progress_timeout(state))
end

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

--- @param bufnr integer
--- @param opts? { force?: boolean, notify_errors?: boolean }
function M.refresh(bufnr, opts)
  opts = opts or {}
  local context_snapshot = context_repository.refresh(bufnr)
  if not context_snapshot or context_snapshot.kind ~= "regular" then
    return nil
  end
  if not context_snapshot.rel_path then
    return nil
  end
  if
    not context_snapshot.vcs_info
    or not context_snapshot.vcs_info.branch
    or context_snapshot.vcs_info.branch == ""
  then
    return nil
  end
  local provider_snapshot = provider_repository.refresh(bufnr)
  if not provider_snapshot then
    return nil
  end
  ensure_subscription(bufnr)
  local progress = opts.progress and start_progress(bufnr, "Refreshing discussions") or nil
  local snapshot = review_repository.refresh(bufnr, opts)
  if snapshot and snapshot.status == "error" and opts.notify_errors ~= false and snapshot.error then
    M._notify("parley: refresh failed: " .. tostring(snapshot.error), vim.log.levels.WARN)
  end
  if progress then
    if snapshot and snapshot.status == "error" then
      finish_progress(progress, bufnr, "failed", "Refresh failed")
    else
      finish_progress(progress, bufnr, "success", "Refresh complete")
    end
  end
  return snapshot
end

--- @param bufnr integer
--- @param opts? { force?: boolean, notify_errors?: boolean }
--- @param callback? fun(snapshot: table|nil): nil
function M.refresh_async(bufnr, opts, callback)
  async.run(function()
    local snapshot = M.refresh(bufnr, opts)
    if callback then
      vim.schedule(function()
        callback(snapshot)
      end)
    end
  end)
end

return M
