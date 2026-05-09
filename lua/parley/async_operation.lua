--- parley.async_operation — async operation wrapper with optional progress popup.
---
--- Wraps a blocking function (run inside an owned plenary.async coroutine) with
--- lifecycle management: progress popup, notify on completion, and a
--- vim-scheduled finally callback that receives the operation result.
---
--- Usage:
---   async_operation.new({
---     bufnr  = bufnr,
---     silent = false,
---     fn     = function() ... return value end,
---     popup  = { progress = "...", success = "...", error = "..." },
---     finally_scheduled_fn = function(ok, result) ... end,
---   }):start()

local progress_ui_state = require("parley.ui_states.progress")

local M = {}

M._next_id = 0

--- @type fun(fn: fun(): any): nil
M._async_run = function(fn)
  require("plenary.async").run(fn)
end

--- @type fun(): integer
M._now = function()
  return math.floor((vim.uv or vim.loop).hrtime() / 1000000)
end

--- @type fun(cb: fun(), timeout: integer): nil
M._defer = function(cb, timeout)
  vim.defer_fn(cb, timeout)
end

--- @type fun(): table
M._get_config = function()
  return require("parley").config
end

--- @param state 'success'|'failed'
--- @return integer
local function timeout_for(state)
  local config = M._get_config() or {}
  local progress = config.progress or {}
  if state == "success" then
    return progress.success_timeout or 1200
  end
  return progress.failed_timeout or 2500
end

-- ---------------------------------------------------------------------------
-- Type annotations
-- ---------------------------------------------------------------------------

--- @class parley.ProgressText
--- @field progress string  shown while the operation is running
--- @field success  string  shown on success
--- @field error    string  shown on failure

--- @class parley.AsyncOperationOpts
--- @field bufnr                 integer
--- @field fn                    fun(): any          return value forwarded to finally_scheduled_fn; throw = failure
--- @field silent                boolean             when true no popup; fn and finally_scheduled_fn still run
--- @field title?                string              progress entry title; defaults to "Parley"
--- @field popup?                parley.ProgressText required when silent = false
--- @field notify?               { success?: string, error?: string }
--- @field finally_scheduled_fn? fun(ok: boolean, result: any): nil
--- called via vim.schedule after fn; result is fn's return on success or the error value on failure

--- @class parley.AsyncOperation
--- @field _opts parley.AsyncOperationOpts
local Operation = {}
Operation.__index = Operation

--- Create a new AsyncOperation.
--- Asserts required fields and validates popup when silent = false.
--- @param opts parley.AsyncOperationOpts
--- @return parley.AsyncOperation
function M.new(opts)
  assert(type(opts.bufnr) == "number", "async_operation: bufnr must be an integer")
  assert(type(opts.fn) == "function", "async_operation: fn must be a function")
  assert(type(opts.silent) == "boolean", "async_operation: silent must be a boolean")
  if not opts.silent then
    assert(type(opts.popup) == "table", "async_operation: popup is required when silent = false")
    assert(type(opts.popup.progress) == "string", "async_operation: popup.progress must be a string")
    assert(type(opts.popup.success) == "string", "async_operation: popup.success must be a string")
    assert(type(opts.popup.error) == "string", "async_operation: popup.error must be a string")
  end
  return setmetatable({ _opts = opts }, Operation)
end

--- Start the operation.
---
--- When silent = false the progress popup is inserted into progress_ui_state
--- synchronously before the async coroutine is scheduled, so the user sees
--- feedback immediately. All final state changes and the finally_scheduled_fn
--- callback happen via vim.schedule, guaranteeing they run on the main loop.
function Operation:start()
  local opts = self._opts

  if opts.silent then
    M._async_run(function()
      local ok, result = pcall(opts.fn)
      if opts.finally_scheduled_fn then
        vim.schedule(function()
          opts.finally_scheduled_fn(ok, result)
        end)
      end
    end)
    return
  end

  M._next_id = M._next_id + 1
  local id = "async-op-" .. tostring(M._next_id)
  local title = opts.title or "Parley"
  local now = M._now()
  local entry = {
    id = id,
    bufnr = opts.bufnr,
    title = title,
    message = opts.popup.progress,
    kind = "operation",
    state = "running",
    started_at = now,
    updated_at = now,
  }
  -- Upsert synchronously so the popup appears before the coroutine is scheduled.
  progress_ui_state.upsert(entry)

  M._async_run(function()
    local ok, result = pcall(opts.fn)

    vim.schedule(function()
      local final_state = ok and "success" or "failed"
      local final_message = ok and opts.popup.success or opts.popup.error
      progress_ui_state.upsert({
        id = id,
        bufnr = opts.bufnr,
        title = title,
        message = final_message,
        kind = "operation",
        state = final_state,
        started_at = entry.started_at,
        updated_at = M._now(),
      })

      M._defer(function()
        progress_ui_state.remove(id)
      end, timeout_for(final_state))

      if opts.notify then
        if ok and opts.notify.success then
          vim.notify(opts.notify.success, vim.log.levels.INFO)
        elseif not ok and opts.notify.error then
          vim.notify(opts.notify.error, vim.log.levels.WARN)
        end
      end

      if opts.finally_scheduled_fn then
        opts.finally_scheduled_fn(ok, result)
      end
    end)
  end)
end

return M
