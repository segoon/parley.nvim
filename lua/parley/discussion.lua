--- Provider-independent discussion semantics; legacy locations remain supported.
local M = {}
--- @alias parley.IssueState 'open'|'resolved'|'dropped'|'not_issue'|'unknown'
--- @class parley.DiscussionAnchor
--- @field kind 'inline'|'file'|'general'|'unavailable'
--- @field path? string Repo-relative path on the anchored side.
--- @field before_path? string
--- @field after_path? string
--- @field side? 'old'|'new'
--- @field revision? string Provider-supplied source revision; never inferred from the current head.
--- @field diff_id? string Opaque provider diff identity.
--- @field line? integer
--- @field end_line? integer
--- @field unavailable_reason? string Why no current-file position can be used.

--- @param path any
--- @return boolean
function M.valid_path(path)
  if type(path) ~= "string" or path == "" or path:find("\0", 1, true) or path:match("^[/\\]") or path:match("^%a:") then
    return false
  end
  for part in path:gmatch("[^/\\]+") do
    if part == ".." then
      return false
    end
  end
  return true
end
--- @param line any
--- @return boolean
function M.valid_line(line)
  return type(line) == "number" and line > 0 and line < math.huge and line == math.floor(line)
end
--- @param discussion parley.Discussion|table
--- @return parley.DiscussionAnchor
function M.anchor(discussion)
  if type(discussion.anchor) == "table" then
    return discussion.anchor
  end
  if M.valid_path(discussion.file) then
    return {
      kind = M.valid_line(discussion.line) and "inline" or "file",
      path = discussion.file,
      line = M.valid_line(discussion.line) and discussion.line or nil,
      end_line = discussion.end_line,
    }
  end
  return { kind = "unavailable", unavailable_reason = "Location unavailable" }
end
--- @param discussion parley.Discussion|table
--- @return boolean
function M.projectable(discussion)
  local a = M.anchor(discussion)
  return a.kind == "inline"
    and M.valid_path(a.path)
    and M.valid_line(a.line)
    and not a.unavailable_reason
    and a.side ~= "old"
end
--- @param discussion parley.Discussion|table
--- @return parley.IssueState
function M.issue_state(discussion)
  return discussion.issue_state or (discussion.resolved and "resolved" or "open")
end
--- @param discussion parley.Discussion|table
--- @return boolean
function M.is_open_issue(discussion)
  return M.issue_state(discussion) == "open"
end
--- @param state table
--- @param id string
--- @return parley.Discussion|nil
function M.find(state, id)
  for _, list in ipairs({ state.all_discussions or {}, state.discussions or {} }) do
    for _, discussion in ipairs(list) do
      if discussion.id == id then
        return discussion
      end
    end
  end
end
return M
