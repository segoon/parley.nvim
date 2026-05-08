--- parley.runtime.ui — helpers for crossing into the main loop safely.

local M = {}

--- @param fn fun()
function M.dispatch(fn)
  if vim.in_fast_event() then
    vim.schedule(fn)
    return
  end
  fn()
end

--- @generic T
--- @param cb fun(...: T)
--- @return fun(...: T)
function M.wrap(cb)
  return function(...)
    local argc = select("#", ...)
    local argv = { ... }
    M.dispatch(function()
      cb(unpack(argv, 1, argc))
    end)
  end
end

--- @param where string
function M.assert_main_loop(where)
  assert(not vim.in_fast_event(), string.format("parley: %s must run on the main loop", where))
end

return M
