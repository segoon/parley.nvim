--- parley.providers.github.mapping — Pure data-mapping helpers.
---
--- Converts raw GitHub REST API objects (review comments, reactions, reviews)
--- into parley model types.  No I/O; all functions are pure.

local dbg = require("parley.debug")
local model = require("parley.model")

local M = {}

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

--- Map REST reactions object keys → internal reaction type strings.
--- @type string[]
M.REST_REACTION_KEYS = require("parley.providers.github.reactions").keys()

--- Map GitHub review states → parley.ReviewStatus values.
--- @type table<string, string>
M.GH_REVIEW_STATE_MAP = {
  APPROVED = "approved",
  CHANGES_REQUESTED = "changes_requested",
  DISMISSED = "dismissed",
  COMMENTED = "commented",
}

--- Map provider event names → GitHub review event values.
--- @type table<string, string>
M.REVIEW_EVENT_MAP = {
  approve = "APPROVE",
  request_changes = "REQUEST_CHANGES",
  comment = "COMMENT",
}

--- GraphQL query fetching review-thread resolution state and node ids for a
--- PR, paginated via reviewThreads(first, after: $cursor). Only the first
--- comment of each thread is requested — its databaseId is the REST review
--- comment id already used as parley.Discussion.id, letting us correlate
--- GraphQL threads to REST-derived discussions.
--- @type string
M.REVIEW_THREADS_QUERY = [[
query($owner: String!, $repo: String!, $number: Int!, $cursor: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          isResolved
          comments(first: 1) {
            nodes { databaseId }
          }
        }
      }
    }
  }
}
]]

--- @type string
M.RESOLVE_THREAD_MUTATION = [[
mutation($id: ID!) {
  resolveReviewThread(input: { threadId: $id }) {
    thread { id isResolved }
  }
}
]]

--- @type string
M.UNRESOLVE_THREAD_MUTATION = [[
mutation($id: ID!) {
  unresolveReviewThread(input: { threadId: $id }) {
    thread { id isResolved }
  }
}
]]

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Compute review_status from a list of GitHub review objects.
--- Takes the last non-PENDING entry (reviews are in chronological order).
--- @param reviews table[]
--- @return parley.ReviewStatus
function M.compute_review_status(reviews)
  local status = "pending"
  for _, r in ipairs(reviews) do
    local mapped = M.GH_REVIEW_STATE_MAP[r.state]
    if mapped then
      status = mapped
    end
  end
  return status
end

--- Map the REST reactions object (embedded in a comment) to parley.Reaction[].
--- The REST API embeds counts as `{"+1": N, "-1": N, ...}` under `reactions`.
--- Only includes reaction types with count > 0.
--- @param raw table  the `reactions` sub-object from a REST review comment
--- @return parley.Reaction[]
function M.map_rest_reactions(raw)
  if not raw then
    return {}
  end
  local result = {}
  for _, key in ipairs(M.REST_REACTION_KEYS) do
    local count = raw[key]
    if type(count) == "number" and count > 0 then
      table.insert(
        result,
        model.new_reaction({
          type = key,
          count = count,
          -- REST comment reactions do not expose per-viewer state;
          -- viewer_reacted is determined lazily in react() via a separate call.
          viewer_reacted = false,
        })
      )
    end
  end
  return result
end

--- Map a single raw REST review comment to a parley.Comment.
--- @param raw    table   Raw GitHub review comment object
--- @param viewer string  Authenticated viewer's login (for is_own)
--- @return parley.Comment
function M.map_rest_comment(raw, viewer)
  local parent_id = nil
  if raw.in_reply_to_id and raw.in_reply_to_id ~= vim.NIL then
    parent_id = tostring(raw.in_reply_to_id)
  end
  return model.new_comment({
    id = tostring(raw.id),
    author = raw.user and raw.user.login or "",
    body = model.new_body({ text = raw.body or "", format = "markdown" }),
    created_at = raw.created_at or "",
    updated_at = raw.updated_at or "",
    reactions = M.map_rest_reactions(raw.reactions),
    is_own = (raw.user and raw.user.login == viewer) or false,
    parent_comment_id = parent_id,
    url = type(raw.html_url) == "string" and raw.html_url or nil,
  })
end

--- Build form fields for a top-level comment anchor.
--- @param file string
--- @param anchor parley.Anchor
--- @param body parley.Body
--- @param write_context parley.github.WriteContext
--- @return string[]
function M.build_top_level_fields(file, anchor, body, write_context)
  local start_line = anchor.start_line
  local end_line = anchor.end_line
  dbg.trace(
    "github.mapping",
    "build_top_level_fields: file="
      .. tostring(file)
      .. " start_line="
      .. tostring(start_line)
      .. " end_line="
      .. tostring(end_line)
      .. " head_sha="
      .. tostring(write_context.head_sha)
  )
  local fields = {
    "-f",
    "body=" .. body.text,
    "-f",
    "commit_id=" .. write_context.head_sha,
    "-f",
    "path=" .. file,
    "-f",
    "side=RIGHT",
  }

  if end_line and end_line ~= start_line then
    fields[#fields + 1] = "-F"
    fields[#fields + 1] = "start_line=" .. tostring(start_line)
    fields[#fields + 1] = "-f"
    fields[#fields + 1] = "start_side=RIGHT"
    fields[#fields + 1] = "-F"
    fields[#fields + 1] = "line=" .. tostring(end_line)
  else
    fields[#fields + 1] = "-F"
    fields[#fields + 1] = "line=" .. tostring(start_line)
  end

  dbg.trace("github.mapping", "build_top_level_fields: fields=" .. vim.inspect(fields))
  return fields
end

--- Map GraphQL reviewThreads nodes into a lookup keyed by root REST comment id.
--- Nodes without a first comment (shouldn't happen) are skipped.
--- @param nodes table[]  raw `reviewThreads.nodes` GraphQL objects
--- @return table<string, { node_id: string, resolved: boolean }>
function M.map_review_thread_nodes(nodes)
  local result = {}
  for _, node in ipairs(nodes or {}) do
    local comments = node.comments and node.comments.nodes or {}
    local first = comments[1]
    local database_id = first and first.databaseId
    if database_id and database_id ~= vim.NIL then
      result[tostring(database_id)] = {
        node_id = node.id,
        resolved = node.isResolved == true,
      }
    end
  end
  return result
end

--- Group a flat list of REST review comments into parley.Discussion[].
---
--- Grouping rules:
---   • A comment with no in_reply_to_id is a root → new Discussion.
---   • A comment with in_reply_to_id belongs to the Discussion whose id equals
---     that value (GitHub always points replies at the root, not a direct parent).
---
--- @param comments table[]  Raw GitHub review comment objects (ordered by created_at)
--- @param viewer   string   Authenticated viewer's login
--- @return parley.Discussion[]
function M.group_comments_into_discussions(comments, viewer)
  --- @type table<string, parley.Discussion>
  local by_root = {}
  --- @type string[]  Insertion-order list of root ids (for stable output order)
  local order = {}

  for _, raw in ipairs(comments) do
    local is_root = not raw.in_reply_to_id or raw.in_reply_to_id == vim.NIL
    local comment = M.map_rest_comment(raw, viewer)

    if is_root then
      local root_id = tostring(raw.id)
      local line = raw.line
      if not line or line == vim.NIL then
        line = raw.original_line or 0
      end
      local disc = model.new_discussion({
        id = root_id,
        url = comment.url,
        file = raw.path or "",
        line = line,
        end_line = (raw.start_line and raw.start_line ~= vim.NIL) and raw.line or nil,
        resolved = false, -- overlaid with real state from GraphQL by the provider
        comments = { comment },
      })
      by_root[root_id] = disc
      table.insert(order, root_id)
    else
      local root_id = tostring(raw.in_reply_to_id)
      local disc = by_root[root_id]
      if disc then
        table.insert(disc.comments, comment)
      end
      -- If root not seen yet (shouldn't happen with GitHub's ordering), skip.
    end
  end

  local result = {}
  for _, root_id in ipairs(order) do
    table.insert(result, by_root[root_id])
  end
  return result
end

return M
