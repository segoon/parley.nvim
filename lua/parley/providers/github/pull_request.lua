--- GitHub CLI PR metadata and aggregate review decision.
local model = require("parley.model")
local transport = require("parley.providers.github.transport")
local M = {}

local FIELDS = "number,title,state,baseRefName,headRefName,headRefOid,author,url,reviewDecision"
local QUERY = [[
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      number title state baseRefName headRefName headRefOid author { login } url reviewDecision
    }
  }
}
]]
local DECISIONS = { APPROVED = "approved", CHANGES_REQUESTED = "changes_requested", REVIEW_REQUIRED = "pending" }

--- gh pr view cannot select custom API URLs and interprets numeric selectors as PR numbers.
--- Keep the explicit open-branch REST lookup for these cases, then fetch the same GraphQL fields.
--- @param self parley.github.Provider
--- @param branch string
--- @return table|nil
local function api_metadata(self, branch)
  local pulls = transport.gh_run(self, {
    "gh",
    "api",
    "/repos/" .. self._owner .. "/" .. self._repo .. "/pulls",
    "--method",
    "GET",
    "-f",
    "head=" .. self._owner .. ":" .. branch,
    "-f",
    "state=open",
    "-F",
    "per_page=1",
  })
  assert(type(pulls) == "table" and vim.islist(pulls), "GitHub returned an invalid PR list; refresh the review")
  if #pulls == 0 then
    return nil
  end
  assert(type(pulls[1]) == "table" and type(pulls[1].number) == "number", "GitHub returned an invalid PR number")
  local data =
    transport.gh_graphql(self, QUERY, { owner = self._owner, repo = self._repo, number = pulls[1].number }, "read")
  assert(
    type(data) == "table" and type(data.repository) == "table" and data.repository.pullRequest ~= nil,
    "GitHub returned invalid PR metadata; refresh the review"
  )
  local raw = data.repository.pullRequest
  return raw ~= vim.NIL and raw or nil
end

--- Detect an open PR without locally interpreting individual review history.
--- @param self parley.github.Provider
--- @param _repo_root string
--- @param branch string
--- @return parley.DetectedReview|nil
function M.detect(self, _repo_root, branch)
  local raw
  if transport.uses_custom_api_base(self) or branch:match("^#?[+-]?%d+$") then
    raw = api_metadata(self, branch)
    if raw == nil then
      return nil
    end
  else
    local ok, result = pcall(transport.gh_run, self, { "gh", "pr", "view", branch, "--json", FIELDS }, "read")
    if not ok then
      -- gh pr view has no structured not-found result. Match only its branch diagnostic;
      -- authentication, GraphQL and transport failures must still surface to the caller.
      local absent = "parley.github: gh command failed (exit 1): no pull requests found for branch "
      if tostring(result):sub(1, #absent) == absent then
        return nil
      end
      error(result, 0)
    end
    raw = result
  end
  assert(type(raw) == "table", "GitHub returned invalid PR metadata; refresh the review")
  if raw.state == "CLOSED" or raw.state == "MERGED" then
    return nil
  end
  assert(
    raw.state == "OPEN"
      and type(raw.number) == "number"
      and raw.number > 0
      and raw.number % 1 == 0
      and type(raw.headRefOid) == "string"
      and raw.headRefOid ~= ""
      and raw.headRefName == branch,
    "GitHub returned incomplete or mismatched PR metadata; refresh the review"
  )
  local pr = model.new_pr({
    id = tostring(raw.number),
    title = raw.title or "",
    state = "open",
    base_branch = raw.baseRefName or "",
    head_branch = raw.headRefName,
    author = type(raw.author) == "table" and raw.author.login or "",
    url = raw.url or "",
    review_status = type(raw.reviewDecision) == "string" and DECISIONS[raw.reviewDecision] or "unknown",
  })
  return { pr = pr, head_sha = raw.headRefOid, write_context = { head_sha = raw.headRefOid, number = raw.number } }
end
return M
