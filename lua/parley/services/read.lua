--- parley.services.read — read-side rendering wrapper over repositories.

local async = require("plenary.async")
local context_repository = require("parley.repositories.context")
local provider_repository = require("parley.repositories.provider")
local review_repository = require("parley.repositories.review")
local signs = require("parley.signs")

local M = {}
M._subscriptions = {}

M._notify = function(msg, level)
  vim.notify(msg, level)
end

M._get_config = function()
  return require("parley").config
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
  local snapshot = review_repository.refresh(bufnr, opts)
  if snapshot and snapshot.status == "error" and opts.notify_errors ~= false and snapshot.error then
    M._notify("parley: refresh failed: " .. tostring(snapshot.error), vim.log.levels.WARN)
  end
  return snapshot
end

--- @param bufnr integer
--- @param opts? { force?: boolean, notify_errors?: boolean }
function M.refresh_async(bufnr, opts)
  async.run(function()
    M.refresh(bufnr, opts)
  end)
end

return M
