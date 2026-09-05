--- Issue-state writes share the cancellable transport; PATCH is never retried automatically.
local transport = require("parley.providers.arcanum.transport")
local await = require("parley.runtime.await")
local M = {}
--- @param id string
local function validate_id(id)
  assert(type(id) == "string" and id:match("^%d+$"), "Arcanum issue requires a numeric root comment ID")
end
--- @param provider parley.arcanum.Provider
--- @param id string
--- @param state 'open'|'resolved'
--- @param callback parley.WriteCallback
--- @return parley.CancelHandle
local function begin(provider, id, state, callback)
  validate_id(id)
  local ok, err = pcall(provider.auth, provider)
  if not ok then
    callback({ ok = false, err = tostring(err) })
    return { cancel = function() end }
  end
  return transport.http_start(
    provider,
    "PATCH",
    "/v1/public/review-requests-comments/" .. id,
    { issue_status = state },
    function(result)
      callback({ ok = result.ok, err = result.err, uncertain = result.uncertain, cancelled = result.cancelled })
    end,
    { retry_policy = "none" }
  )
end
--- @param self parley.arcanum.Provider
--- @param _review parley.DetectedReview
--- @param id string
--- @param callback parley.WriteCallback
--- @return parley.CancelHandle
function M.begin_resolve(self, _review, id, callback)
  return begin(self, id, "resolved", callback)
end
--- @param self parley.arcanum.Provider
--- @param _review parley.DetectedReview
--- @param id string
--- @param callback parley.WriteCallback
--- @return parley.CancelHandle
function M.begin_unresolve(self, _review, id, callback)
  return begin(self, id, "open", callback)
end
--- @param provider parley.arcanum.Provider
--- @param id string
--- @param state 'open'|'resolved'
local function run(provider, id, state)
  validate_id(id)
  local result = await.callback(function(cb)
    begin(provider, id, state, cb)
  end)
  if not result.ok then
    error(result.err or "Arcanum issue update failed", 0)
  end
end
--- @param self parley.arcanum.Provider
--- @param _review parley.DetectedReview
--- @param id string
function M.resolve(self, _review, id)
  run(self, id, "resolved")
end
--- @param self parley.arcanum.Provider
--- @param _review parley.DetectedReview
--- @param id string
function M.unresolve(self, _review, id)
  run(self, id, "open")
end
return M
