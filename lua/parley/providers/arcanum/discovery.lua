--- Exhaust prefix search pages before reporting that the exact remote branch has no review.
local transport = require("parley.providers.arcanum.transport")
local M = {}
local fields = "id,summary,status,url,author,vcs"
--- @param self parley.arcanum.Provider
--- @param branch string
--- @return table|nil
function M.find(self, branch)
  local offset, seen = 0, {}
  while true do
    local data = transport.http_run(self, "POST", "/v1/pull-requests/cursor", {
      limit = 100,
      offset = offset,
      desc_order = true,
      filter = { user_branch_prefix = branch, state = { published = true } },
    }, { retry_policy = "read" })
    if
      type(data) ~= "table"
      or type(data.pull_requests) ~= "table"
      or not vim.islist(data.pull_requests)
      or type(data.has_next) ~= "boolean"
    then
      error("Arcanum review search returned an invalid page", 0)
    end
    local progress = false
    for _, candidate in ipairs(data.pull_requests) do
      local id = type(candidate) == "table" and candidate.id
      if type(id) ~= "number" or id <= 0 or id ~= math.floor(id) or id == math.huge then
        error("Arcanum review search returned an invalid candidate ID", 0)
      end
      if not seen[id] then
        seen[id], progress = true, true
        local full = transport.http_run(self, "GET", "/v1/pull-requests/" .. tostring(id) .. "?fields=" .. fields)
        if
          type(full) ~= "table"
          or full.id ~= id
          or type(full.vcs) ~= "table"
          or type(full.vcs.from_branch) ~= "string"
        then
          error("Arcanum review search returned incomplete candidate details", 0)
        end
        if full.vcs.from_branch == branch then
          return full
        end
      end
    end
    if not data.has_next then
      return nil
    end
    if not progress then
      error("Arcanum review search did not advance; refresh the review", 0)
    end
    offset = offset + #data.pull_requests
  end
end
return M
