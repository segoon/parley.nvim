--- Lossless parent-graph grouping with explicit Arcanum issue and anchor semantics.
local model = require("parley.model")
local tree = require("parley.comment_tree")
local anchors = require("parley.providers.arcanum.anchors")
local M = {}
--- @param raw any
--- @return parley.IssueState
local function issue_state(raw)
  if raw == nil or raw == vim.NIL or raw == "not_issue" then
    return "not_issue"
  end
  if raw == "open" or raw == "resolved" or raw == "dropped" then
    return raw
  end
  return "unknown"
end
--- @param raw_comments table[]
--- @param viewer string
--- @param review parley.DetectedReview|nil
--- @param map_comment fun(raw: table, viewer: string): parley.Comment
--- @return parley.Discussion[]
function M.group(raw_comments, viewer, review, map_comment)
  local comments, raw_by_id = {}, {}
  for _, raw in ipairs(raw_comments) do
    local comment = map_comment(raw, viewer)
    comments[#comments + 1], raw_by_id[comment.id] = comment, raw
  end
  local discussions = {}
  for _, group in ipairs(tree.groups(comments)) do
    local ordered, _, ancestry = tree.order(group)
    local root = ordered[1]
    local raw = raw_by_id[root.id]
    discussions[#discussions + 1] = model.new_discussion({
      id = root.id,
      anchor = anchors.map(raw.anchor, review),
      issue_state = issue_state(raw.issue_status),
      comments = ordered,
      ancestry = ancestry,
    })
  end
  return discussions
end
return M
