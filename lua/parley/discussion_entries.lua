--- parley.discussion_entries — shared discussion list formatting helpers.

local M = {}

--- @param text string
--- @param max_width? integer
--- @return string
function M.snippet(text, max_width)
  local width = max_width or 60
  text = (text or ""):gsub("%s+", " ")
  if #text <= width then
    return text
  end
  return text:sub(1, width - 3) .. "..."
end

--- @param discussion parley.Discussion
--- @return string
function M.status(discussion)
  return discussion.resolved and "resolved" or "unresolved"
end

--- @param discussion parley.Discussion
--- @param max_width? integer
--- @return string
function M.summary_text(discussion, max_width)
  local first_comment = discussion.comments and discussion.comments[1] or nil
  local author = first_comment and first_comment.author or "unknown"
  local preview = M.snippet(first_comment and first_comment.body and first_comment.body.text or "", max_width)
  local status = M.status(discussion)
  if preview == "" then
    return string.format("[%s] %s", status, author)
  end
  return string.format("[%s] %s: %s", status, author, preview)
end

--- @param discussion parley.Discussion
--- @param root string
--- @param mappings? table<string, parley.anchor.Mapping>
--- @return { path: string, line: integer, status: string, preview: string, text: string }
function M.location(discussion, root, mappings)
  local mapping = mappings and mappings[discussion.id] or nil
  local line = mapping and mapping.local_line or discussion.line
  local first_comment = discussion.comments and discussion.comments[1] or nil
  local preview = M.snippet(first_comment and first_comment.body and first_comment.body.text or "")
  return {
    path = root .. "/" .. discussion.file,
    line = line,
    status = M.status(discussion),
    preview = preview,
    text = M.summary_text(discussion),
  }
end

return M
