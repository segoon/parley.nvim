local M = {}
local semantics = require("parley.discussion")
local tree = require("parley.comment_tree")
local entries = require("parley.discussion_entries")

---@param text string
---@return string[]
local function split_lines(text)
  if text == "" then
    return { "" }
  end
  return vim.split(text, "\n", { plain = true })
end

---@param presentation? fun(code: string): parley.ReactionPresentation
---@param reactions parley.Reaction[]
---@return string|nil
local function reaction_summary(reactions, presentation)
  if #reactions == 0 then
    return nil
  end

  local parts = {}
  for _, reaction in ipairs(reactions) do
    local suffix = reaction.viewer_reacted and " (you)" or ""
    local display = presentation and presentation(reaction.type) or { label = reaction.type }
    local emoji = display.emoji or display.label or reaction.type
    local count = reaction.count > 1 and string.format(" x%d", reaction.count) or ""
    parts[#parts + 1] = string.format("%s%s%s", emoji, count, suffix)
  end
  return "Reactions: " .. table.concat(parts, ", ")
end

---@param discussion parley.Discussion
---@param mapping parley.anchor.Mapping|nil
---@param out string[]
---@param ranges table<string, { start_line: integer, end_line: integer }>
---@param deps { format_timestamp: fun(timestamp: string): string,
--- reaction_presentation?: fun(code: string): parley.ReactionPresentation }
---@return string
local function render_discussion(discussion, mapping, out, ranges, deps)
  local title = entries.status(discussion)
  if discussion.anchor then
    title = title .. " · " .. semantics.anchor(discussion).kind
  end
  if mapping and mapping.stale then
    title = title .. " · stale"
  end

  if #discussion.comments == 0 then
    out[#out + 1] = "(no comments in the discussion yet)"
    out[#out + 1] = ""
    return title
  end

  local ordered, depths, ancestry = tree.order(discussion.comments)
  local a = discussion.anchor
  if a then
    local parts = { a.path or (a.kind == "general" and "General discussion" or "Location unavailable") }
    if a.side then
      parts[#parts + 1] = a.side .. " side"
    end
    if a.line then
      parts[#parts + 1] = "line " .. a.line .. (a.end_line and ("–" .. a.end_line) or "")
    end
    if a.diff_id then
      parts[#parts + 1] = "diff " .. a.diff_id
    end
    if a.revision then
      parts[#parts + 1] = "revision " .. a.revision
    end
    if a.unavailable_reason then
      parts[#parts + 1] = a.unavailable_reason
    end
    out[#out + 1], out[#out + 2] = table.concat(parts, " · "), ""
  end
  if ancestry or discussion.ancestry then
    out[#out + 1] = (ancestry or discussion.ancestry) == "cycle" and "Thread contains cyclic ancestry."
      or "Some parent comments are unavailable."
    out[#out + 1] = ""
  end
  for _, comment in ipairs(ordered) do
    local depth = math.min(depths[comment.id], 12)
    local indent = string.rep("  ", depth)
    local start_line = #out + 1

    out[#out + 1] = string.format("%s- **%s** · %s", indent, comment.author, deps.format_timestamp(comment.created_at))
    for _, line in ipairs(split_lines(comment.body.text)) do
      out[#out + 1] = string.format("%s  %s", indent, line)
    end

    local reactions = reaction_summary(comment.reactions, deps.reaction_presentation)
    if reactions then
      out[#out + 1] = string.format("%s  ---", indent)
      out[#out + 1] = string.format("%s  %s", indent, reactions)
    end
    ranges[comment.id] = { start_line = start_line, end_line = #out }
    out[#out + 1] = ""
  end

  return title
end

---@param discussions parley.Discussion[]
---@param mappings table<string, parley.anchor.Mapping>
---@param deps { format_timestamp: fun(timestamp: string): string,
--- reaction_presentation?: fun(code: string): parley.ReactionPresentation }
---@return string[], table<string, { start_line: integer, end_line: integer }>, string|nil
function M.render_lines(discussions, mappings, deps)
  local out = {}
  local ranges = {}

  local discussion = discussions[1]
  if not discussion then
    return out, ranges, nil
  end

  local title = render_discussion(discussion, mappings[discussion.id], out, ranges, deps)

  while #out > 0 and out[#out] == "" do
    table.remove(out)
  end

  return out, ranges, title
end

return M
