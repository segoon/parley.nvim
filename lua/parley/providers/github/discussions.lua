--- REST discussions with GraphQL resolution metadata.
local mapping = require("parley.providers.github.mapping")
local transport = require("parley.providers.github.transport")
local dbg = require("parley.debug")
local M = {}

--- Fetch review-thread resolution state + node ids for a PR via GraphQL,
--- paginating through reviewThreads until exhausted.
--- @param self parley.github.Provider
--- @param review parley.DetectedReview
--- @return table<string, { node_id: string, resolved: boolean }>
local function fetch_review_threads(self, review)
  local pr_number = review.write_context and review.write_context.number or tonumber(review.pr.id)
  local lookup = {}
  local variables = {
    owner = self._owner,
    repo = self._repo,
    number = pr_number,
  }
  local pages
  if transport.uses_custom_api_base(self) then
    -- gh only recognizes the literal graphql endpoint for automatic pagination.
    pages = {}
    local seen = {}
    repeat
      local data = transport.gh_graphql(self, mapping.REVIEW_THREADS_QUERY, variables, "read")
      local conn = data
        and data.repository
        and data.repository.pullRequest
        and data.repository.pullRequest.reviewThreads
      assert(conn and conn.pageInfo, "Missing GitHub review-thread page information")
      pages[#pages + 1] = data
      local next_cursor = conn.pageInfo.hasNextPage and conn.pageInfo.endCursor or nil
      if conn.pageInfo.hasNextPage then
        assert(
          type(next_cursor) == "string" and next_cursor ~= "" and not seen[next_cursor],
          "Invalid GitHub page cursor"
        )
        seen[next_cursor] = true
      end
      variables.endCursor = next_cursor
    until not variables.endCursor
  else
    pages = transport.gh_graphql_pages(self, mapping.REVIEW_THREADS_QUERY, variables)
  end
  for _, data in ipairs(pages) do
    local conn = data and data.repository and data.repository.pullRequest and data.repository.pullRequest.reviewThreads
    if conn then
      for id, entry in pairs(mapping.map_review_thread_nodes(conn.nodes or {})) do
        lookup[id] = entry
      end
    end
  end
  return lookup
end

--- Fetch all discussions for a PR using the REST review-comments endpoint.
--- Discussions are grouped by root comment id. Resolution state and thread
--- node ids are then fetched via GraphQL and overlaid by root comment id;
--- a GraphQL failure degrades to resolved=false rather than failing the
--- whole fetch (resolve/unresolve will error until the next successful
--- refresh repopulates the thread node id cache).
--- @param self parley.github.Provider
--- @param review parley.DetectedReview
--- @return parley.Discussion[]
function M.fetch(self, review)
  local pr_number = review.write_context and review.write_context.number or tonumber(review.pr.id)
  local url = ("/repos/" .. self._owner .. "/" .. self._repo) .. "/pulls/" .. pr_number .. "/comments"

  local comments = transport.gh_run(self, { "gh", "api", "--paginate", url }) or {}

  -- Resolve viewer login for is_own detection.
  transport.fetch_viewer_login(self)
  local viewer = self._viewer_login or ""
  dbg.trace(
    "github.provider",
    "fetch_discussions: viewer=" .. vim.inspect(viewer) .. " #comments=" .. tostring(#comments)
  )

  local discussions = mapping.group_comments_into_discussions(comments, viewer)

  self._thread_node_ids = {}
  local ok, lookup = pcall(fetch_review_threads, self, review)
  if ok then
    for _, d in ipairs(discussions) do
      local entry = lookup[d.id]
      if entry then
        d.resolved = entry.resolved
        self._thread_node_ids[d.id] = entry.node_id
      end
    end
  else
    dbg.trace("github.provider", "fetch_discussions: review-thread fetch failed: " .. tostring(lookup))
  end

  local own_count = 0
  for _, d in ipairs(discussions) do
    for _, c in ipairs(d.comments) do
      if c.is_own then
        own_count = own_count + 1
      end
    end
  end
  dbg.trace(
    "github.provider",
    "fetch_discussions: #discussions=" .. tostring(#discussions) .. " is_own_count=" .. tostring(own_count)
  )
  return discussions
end

return M
