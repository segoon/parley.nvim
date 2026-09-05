--- Preserve Arcanum anchor identities; only verified current new-side lines project.
local semantics = require("parley.discussion")
local M = {}
--- @param value any
--- @return table
local function object(value)
  return type(value) == "table" and value or {}
end
--- @param value any
--- @return string|nil
local function text(value)
  return type(value) == "string" and value ~= "" and value or nil
end
--- @param value any
--- @return string|nil
local function path(value)
  return semantics.valid_path(value) and value or nil
end
--- @param raw any
--- @param review? parley.DetectedReview
--- @return parley.DiscussionAnchor
function M.map(raw, review)
  local a = object(raw)
  local rr, commit = object(a.review_request), object(a.commit)
  local diff = object(rr.diff)
  if rr.id and (rr.diff == nil or rr.diff == vim.NIL) then
    return { kind = "general" }
  end
  local file = object(diff.file or commit.file)
  local entry = object(file.entry_id)
  local before, after = object(entry.content_id_before), object(entry.content_id_after)
  local position = object(file.position)
  local side = position.side == "old" and "old" or position.side == "new" and "new" or nil
  local before_path, after_path = path(before.path), path(after.path)
  local selected, source = after_path, after
  if side == "old" then
    selected, source = before_path, before
  end
  local location = selected or path(file.path) or before_path
  local xid = text(diff.diff_set_xid)
  local result = {
    kind = "unavailable",
    path = location,
    before_path = before_path,
    after_path = after_path,
    side = side,
    diff_id = xid,
    revision = text(commit.revision) or text(source.commit_id),
  }
  if not location then
    result.unavailable_reason = "File location unavailable"
    return result
  end
  if position.line == -1 or next(position) == nil then
    result.kind = "file"
  elseif semantics.valid_line(position.line) and semantics.valid_line(position.size or 1) then
    result.kind, result.line = "inline", position.line
    if (position.size or 1) > 1 then
      result.end_line = position.line + position.size - 1
    end
  else
    result.unavailable_reason = "Invalid line position"
    return result
  end
  local context = review and review.write_context or {}
  local target = xid and (xid:match("^%d+%-(%d+)$") or xid:match("^(%d+)$"))
  if file.diff_entry_encrypted == true or before.encrypted == true or after.encrypted == true then
    result.unavailable_reason = "Encrypted file"
  elseif side == "old" then
    result.unavailable_reason = "Old-side location"
  elseif entry.content_id_after == vim.NIL or (next(entry) ~= nil and not after_path) then
    result.unavailable_reason = "File absent from the new side"
  elseif not target or not context.diff_id or tonumber(target) ~= context.diff_id then
    result.unavailable_reason = "Historical or unverified diff"
  elseif not review or not text(review.head_sha) or side ~= "new" then
    result.unavailable_reason = "Revision or side unavailable"
  end
  return result
end
return M
