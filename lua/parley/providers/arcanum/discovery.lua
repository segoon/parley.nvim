--- Find the latest exact-branch PR; closed and unpublished reviews remain inactive.
local transport = require("parley.providers.arcanum.transport")
local requests = require("parley.providers.arcanum.requests")
local await = require("parley.runtime.await")
local session = require("parley.providers.arcanum.session")
local M = {}
local active = {
  open = true,
  conflicts = true,
  errors = true,
  configuration_failed = true,
  merging = true,
  merge_failed = true,
  uploading = true,
  no_changes = true,
}
local inactive = { merged = true, discarded = true, draft = true }

--- @param self parley.arcanum.Provider
--- @param branch string
--- @return table|nil
function M.find(self, branch)
  local token, host, viewer = self._session_token, self._host, self._viewer_login
  local result = await.callback(function(callback)
    transport.request_start(self, requests.get_pr_by_branch(branch), callback)
  end)
  session.require_current(self)
  if self._session_token ~= token or self._host ~= host or self._viewer_login ~= viewer then
    error("Arcanum session changed during branch lookup; refresh the review", 0)
  end
  if not result.ok then
    if result.status == 404 and not result.cancelled and not result.timed_out then
      return nil
    end
    error(result.err or "Arcanum branch lookup failed; refresh the review", 0)
  end
  local data = result.data
  if
    type(data) ~= "table"
    or type(data.id) ~= "number"
    or data.id <= 0
    or data.id == math.huge
    or data.id ~= math.floor(data.id)
    or type(data.vcs) ~= "table"
    or data.vcs.from_branch ~= branch
    or type(data.status) ~= "string"
    or not (active[data.status] or inactive[data.status])
  then
    error("Arcanum branch lookup returned invalid or inconsistent PR metadata; refresh the review", 0)
  end
  return active[data.status] and data or nil
end
return M
