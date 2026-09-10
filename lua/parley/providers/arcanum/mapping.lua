--- parley.providers.arcanum.mapping — Pure data-mapping helpers.
---
--- Converts raw Arcanum REST API objects (comments, PRs, reactions) into
--- parley model types.  No I/O; all functions are pure.

local model = require("parley.model")

local M = {}

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Aggregate a flat list of PublicReactionDto into parley.Reaction[].
--- Groups by reaction code; counts per code; marks viewer_reacted=true when
--- the viewer login matches.
--- @param reactions table[]  PublicReactionDto list (may be nil)
--- @param viewer    string   Authenticated user login
--- @return parley.Reaction[]
function M.map_reactions(reactions, viewer)
  if type(reactions) ~= "table" or #reactions == 0 then
    return {}
  end

  --- @type table<string, { count: integer, viewer_reacted: boolean }>
  local by_code = {}

  for _, r in ipairs(reactions) do
    local code = r.code
    if type(code) == "string" and code ~= "" then
      if not by_code[code] then
        by_code[code] = { count = 0, viewer_reacted = false }
      end
      by_code[code].count = by_code[code].count + 1
      if type(r.user) == "table" and viewer ~= "" and r.user.name == viewer then
        by_code[code].viewer_reacted = true
      end
    end
  end

  local result = {}
  for code, info in pairs(by_code) do
    table.insert(
      result,
      model.new_reaction({
        type = code,
        count = info.count,
        viewer_reacted = info.viewer_reacted,
      })
    )
  end
  -- Sort for deterministic order
  table.sort(result, function(a, b)
    return a.type < b.type
  end)
  return result
end

--- Map a single raw Arcanum comment (Public_Comment / CommentDto) to a
--- parley.Comment.
---
--- The raw object may come from:
---   - GET /v1/public/review-requests/{pr_id}/comments  (Public_Comment)
---   - POST/PATCH responses (Public_LightComment or CommentDto)
---
--- @param raw    table   Raw Arcanum comment object
--- @param viewer string  Authenticated viewer's login (for is_own)
--- @return parley.Comment
function M.map_comment(raw, viewer)
  local parent_id = nil
  local reply_to = raw.reply_to_id
  if reply_to and reply_to ~= vim.NIL and reply_to ~= 0 then
    parent_id = tostring(reply_to)
  end

  -- Author field: v1 uses raw.user.name, v2 (PublicCommentDto) uses raw.author.name
  local author_obj = type(raw.user) == "table" and raw.user or type(raw.author) == "table" and raw.author or {}
  local author = author_obj.name or ""

  local content = raw.content or ""
  local created_at = raw.created_at or ""
  local updated_at = type(raw.updated_at) == "string" and raw.updated_at
    or type(raw.edited_at) == "string" and raw.edited_at
    or created_at

  local reactions = M.map_reactions(raw.reactions, viewer)

  return model.new_comment({
    id = tostring(raw.id),
    author = author,
    body = model.new_body({ text = content, format = "markdown" }),
    created_at = created_at,
    updated_at = updated_at,
    reactions = reactions,
    is_own = (author == viewer and viewer ~= "") or false,
    parent_comment_id = parent_id,
  })
end

--- Extract the file path and line from an Arcanum comment anchor.
---
--- The anchor structure for a review-request comment is:
---   anchor.review_request.diff.file.path  (string)
---   anchor.review_request.diff.file.position.line  (integer)
---   anchor.review_request.diff.file.position.size  (integer, number of lines)
---   anchor.review_request.diff.file.position.side  ("old"|"new")
---
--- Returns nil, nil if the anchor is absent or does not have file position info.
---
--- @param anchor table|nil
--- @return string|nil, integer|nil, integer|nil  path, line, end_line
function M.extract_anchor_location(anchor)
  if not anchor then
    return nil, nil, nil
  end

  local rr = anchor.review_request
  if not rr then
    return nil, nil, nil
  end

  local diff = rr.diff
  if not diff then
    return nil, nil, nil
  end

  local file = diff.file
  if not file then
    return nil, nil, nil
  end

  local path = file.path
  if not path or path == vim.NIL then
    local entry_id = file.entry_id
    local after = entry_id and entry_id.content_id_after or nil
    local before = entry_id and entry_id.content_id_before or nil

    path = after and after.path or nil
    if not path or path == vim.NIL then
      path = before and before.path or nil
    end
  end

  if not path or path == vim.NIL or path == "" then
    return nil, nil, nil
  end

  local position = file.position
  if not position then
    return path, nil, nil
  end

  local line = position.line
  if not line or line == vim.NIL then
    return path, nil, nil
  end

  local size = position.size
  local end_line = nil
  if type(size) == "number" and size > 1 then
    end_line = line + size - 1
  end

  return path, line, end_line
end

--- @param comments table[]
--- @param viewer string
--- @param review? parley.DetectedReview
--- @return parley.Discussion[]
function M.group_comments_into_discussions(comments, viewer, review)
  return require("parley.providers.arcanum.discussions").group(comments, viewer, review, M.map_comment)
end

--- Map a minimal or full Arcanum PR object to a parley.PR.
---
--- @param raw    table   Raw PR object (MinimalPullRequestDto or Public_PullRequest)
--- @return parley.PR
function M.map_pr(raw)
  local status = raw.status or "unknown"
  local review_status = "unknown"

  local vcs = raw.vcs or {}
  local author = raw.author
  if type(author) == "table" then
    author = author.name or ""
  elseif type(author) ~= "string" then
    author = ""
  end

  return model.new_pr({
    id = tostring(raw.id or ""),
    title = raw.summary or "",
    state = status,
    base_branch = vcs.to_branch or "",
    head_branch = vcs.from_branch or "",
    author = author,
    url = raw.url or "",
    review_status = review_status,
  })
end

return M
