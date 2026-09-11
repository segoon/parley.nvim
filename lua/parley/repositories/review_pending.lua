--- Merge in-flight optimistic comments into an incoming remote snapshot.
local M = {}

--- Provider data remains authoritative for every non-pending field.
--- @param current table
--- @param incoming table
--- @param build_summary fun(discussions: parley.Discussion[]): table
function M.preserve(current, incoming, build_summary)
  local incoming_by_id = {}
  for _, discussion in ipairs(incoming.all_discussions or {}) do
    incoming_by_id[discussion.id] = discussion
  end
  for _, discussion in ipairs(current.all_discussions or {}) do
    local root = discussion.comments and discussion.comments[1]
    if root and root.pending then
      if not incoming_by_id[discussion.id] then
        incoming.all_discussions[#incoming.all_discussions + 1] = vim.deepcopy(discussion)
      end
    else
      local target = incoming_by_id[discussion.id]
      if target then
        for _, comment in ipairs(discussion.comments or {}) do
          if comment.pending then
            target.comments[#target.comments + 1] = vim.deepcopy(comment)
          end
        end
      end
    end
  end
  incoming.summary = build_summary(incoming.all_discussions or {})
end

return M
