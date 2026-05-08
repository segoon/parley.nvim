local M = {}

local REACTION_EMOJI = {
  ["+1"] = "👍",
  ["-1"] = "👎",
  laugh = "😄",
  confused = "😕",
  heart = "❤️",
  hooray = "🎉",
  rocket = "🚀",
  eyes = "👀",
}

local REACTION_CHOICES = {
  { reaction = "+1", emoji = "👍", label = "+1" },
  { reaction = "-1", emoji = "👎", label = "-1" },
  { reaction = "laugh", emoji = "😄", label = "laugh" },
  { reaction = "confused", emoji = "😕", label = "confused" },
  { reaction = "heart", emoji = "❤️", label = "heart" },
  { reaction = "hooray", emoji = "🎉", label = "hooray" },
  { reaction = "rocket", emoji = "🚀", label = "rocket" },
  { reaction = "eyes", emoji = "👀", label = "eyes" },
}

---@param text string
---@return string[]
local function split_lines(text)
  if text == "" then
    return { "" }
  end
  return vim.split(text, "\n", { plain = true })
end

---@param reactions parley.Reaction[]
---@return string|nil
local function reaction_summary(reactions)
  if #reactions == 0 then
    return nil
  end

  local parts = {}
  for _, reaction in ipairs(reactions) do
    local suffix = reaction.viewer_reacted and " (you)" or ""
    local emoji = REACTION_EMOJI[reaction.type] or reaction.type
    local count = reaction.count > 1 and string.format(" x%d", reaction.count) or ""
    parts[#parts + 1] = string.format("%s%s%s", emoji, count, suffix)
  end
  return "Reactions: " .. table.concat(parts, ", ")
end

---@param comment parley.Comment
---@return table[]
function M.reaction_picker_items(comment)
  local by_type = {}
  for _, reaction in ipairs(comment.reactions or {}) do
    by_type[reaction.type] = reaction
  end

  local items = {}
  for _, choice in ipairs(REACTION_CHOICES) do
    local reaction = by_type[choice.reaction]
    items[#items + 1] = vim.tbl_extend("force", choice, {
      count = reaction and reaction.count or 0,
      viewer_reacted = reaction and reaction.viewer_reacted or false,
    })
  end
  return items
end

---@param comment parley.Comment
---@param by_id table<string, parley.Comment>
---@param cache table<string, integer>
---@return integer
local function comment_depth(comment, by_id, cache)
  local cached = cache[comment.id]
  if cached ~= nil then
    return cached
  end

  if not comment.parent_comment_id or not by_id[comment.parent_comment_id] then
    cache[comment.id] = 0
    return 0
  end

  local depth = comment_depth(by_id[comment.parent_comment_id], by_id, cache) + 1
  cache[comment.id] = depth
  return depth
end

---@param discussion parley.Discussion
---@param mapping parley.anchor.Mapping|nil
---@param out string[]
---@param ranges table<string, { start_line: integer, end_line: integer }>
---@param deps { format_timestamp: fun(timestamp: string): string }
local function render_discussion(discussion, mapping, out, ranges, deps)
  local status = discussion.resolved and "resolved" or "unresolved"
  local header = status
  if mapping and mapping.stale then
    header = header .. " · stale anchor"
  end
  out[#out + 1] = header
  out[#out + 1] = ""

  if #discussion.comments == 0 then
    out[#out + 1] = "_No comments in this thread._"
    out[#out + 1] = ""
    return
  end

  local by_id = {}
  local depth_cache = {}
  for _, comment in ipairs(discussion.comments) do
    by_id[comment.id] = comment
  end

  for _, comment in ipairs(discussion.comments) do
    local depth = comment_depth(comment, by_id, depth_cache)
    local indent = string.rep("  ", depth)
    local start_line = #out + 1

    out[#out + 1] = string.format("%s- **%s** · %s", indent, comment.author, deps.format_timestamp(comment.created_at))
    for _, line in ipairs(split_lines(comment.body.text)) do
      out[#out + 1] = string.format("%s  %s", indent, line)
    end

    local reactions = reaction_summary(comment.reactions)
    if reactions then
      out[#out + 1] = string.format("%s  ---", indent)
      out[#out + 1] = string.format("%s  %s", indent, reactions)
    end
    ranges[comment.id] = { start_line = start_line, end_line = #out }
    out[#out + 1] = ""
  end
end

---@param discussions parley.Discussion[]
---@param mappings table<string, parley.anchor.Mapping>
---@param deps { format_timestamp: fun(timestamp: string): string }
---@return string[], table<string, { start_line: integer, end_line: integer }>
function M.render_lines(discussions, mappings, deps)
  local out = {}
  local ranges = {}

  local discussion = discussions[1]
  if not discussion then
    return out, ranges
  end

  render_discussion(discussion, mappings[discussion.id], out, ranges, deps)

  while #out > 0 and out[#out] == "" do
    table.remove(out)
  end

  return out, ranges
end

return M
