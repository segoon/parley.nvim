--- parley.runtime.await — coroutine-safe wrappers around callback APIs.

local async = require("plenary.async")
local ui = require("parley.runtime.ui")

local M = {}

--- @generic T
--- @param register fun(callback: fun(...: T): nil): nil
--- @return ...: T
function M.callback(register)
  local await_callback = async.wrap(function(callback)
    register(ui.wrap(callback))
  end, 1)
  return await_callback()
end

--- @param cmd string[]
--- @param opts? table
--- @return vim.SystemCompleted
function M.system(cmd, opts)
  opts = opts or {}
  local system = opts._system or vim.system
  local system_opts = vim.deepcopy(opts)
  system_opts._system = nil
  return M.callback(function(callback)
    system(cmd, system_opts, callback)
  end)
end

--- @param timeout_ms integer
function M.sleep(timeout_ms)
  M.callback(function(callback)
    local timer = (vim.uv or vim.loop).new_timer()
    timer:start(timeout_ms, 0, function()
      if timer:is_active() then
        timer:stop()
      end
      timer:close()
      callback()
    end)
  end)
end

return M
