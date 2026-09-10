--- parley.discussion_entries — shared discussion list formatting helpers.

local M = {}
local semantics = require("parley.discussion")

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
  local state = semantics.issue_state(discussion)
  return ({
    open = "unresolved",
    resolved = "resolved",
    dropped = "dropped",
    not_issue = "not an issue",
    unknown = "unknown",
  })[state] or "unknown"
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
--- @return { path: string|nil, line: integer|nil, status: string, preview: string, text: string }
function M.location(discussion, root, mappings)
  local a = semantics.anchor(discussion)
  local mapping = mappings and mappings[discussion.id] or nil
  local line
  if semantics.projectable(discussion) then
    if mapping then
      line = mapping.local_line
    elseif not discussion.anchor then
      line = discussion.line
    end
  end
  local path = semantics.valid_path(a.path) and (root .. "/" .. a.path) or nil
  if not path or not semantics.valid_line(line) then
    line = nil
  end
  local first = discussion.comments and discussion.comments[1]
  local preview = M.snippet(first and first.body and first.body.text or "")
  local reason = a.unavailable_reason or mapping and mapping.unavailable_reason
  local category = a.kind == "general" and "general"
    or a.kind == "file" and "whole file"
    or (not line and "unavailable" or nil)
  local prefix = category and ("[" .. category .. "] ") or (mapping and mapping.stale and "[approximate] " or "")
  return {
    path = path,
    line = line,
    status = M.status(discussion),
    preview = preview,
    text = prefix .. M.summary_text(discussion) .. (reason and (" · " .. reason) or ""),
  }
end

--- @param discussion parley.Discussion
--- @param root string
--- @param mappings? table
--- @return string
function M.label(discussion, root, mappings)
  local location = M.location(discussion, root, mappings)
  local a = semantics.anchor(discussion)
  local path = a.path and (a.path .. ":" .. tostring(location.line or "—") .. " ") or ""
  return path .. location.text
end

return M
