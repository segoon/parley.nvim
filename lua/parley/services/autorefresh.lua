--- parley.services.autorefresh — fire a single background refresh per
--- distinct stale-state token, without ever looping or retrying.

local M = {}

--- bufnr -> last token that already triggered a refresh.
--- @type table<integer, string>
M._fired = {}

--- Call `fn()` at most once for a given `(bufnr, token)` pair. Calling again
--- with the same token is a no-op; a different token (new draft, new branch,
--- new condition instance) is free to fire again.
--- @param bufnr integer
--- @param token string
--- @param fn fun(): nil
--- @return boolean fired
function M.once(bufnr, token, fn)
  if M._fired[bufnr] == token then
    return false
  end
  M._fired[bufnr] = token
  fn()
  return true
end

--- Clear the dedupe entry for bufnr, e.g. after a successful refresh restores
--- a healthy state, so a later genuine staleness can autorefresh again.
--- @param bufnr integer
function M.clear(bufnr)
  M._fired[bufnr] = nil
end

return M
