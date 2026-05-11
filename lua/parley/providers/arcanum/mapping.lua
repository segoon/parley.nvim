--- parley.providers.arcanum.mapping — Pure data-mapping helpers.
---
--- Converts raw Arcanum REST API objects (comments, PRs, reactions) into
--- parley model types.  No I/O; all functions are pure.

local dbg = require("parley.debug")
local model = require("parley.model")

local M = {}

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

--- Map Arcanum PR status values → parley.ReviewStatus values.
--- Arcanum doesn't have per-reviewer verdicts in the public API listing;
--- we derive a coarse review_status from the PR status field.
--- @type table<string, parley.ReviewStatus>
M.PR_STATUS_MAP = {
  open = "pending",
  uploading = "pending",
  conflicts = "pending",
  errors = "pending",
  configuration_failed = "pending",
  merging = "pending",
  merge_failed = "pending",
  merged = "approved",
  discarded = "dismissed",
  no_changes = "pending",
  unknown = "pending",
}

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
  if not reactions or #reactions == 0 then
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
      if r.user and r.user.name == viewer then
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
  local author_obj = raw.user or raw.author or {}
  local author = author_obj.name or ""

  local content = raw.content or ""
  local created_at = raw.created_at or ""
  local updated_at = raw.updated_at or raw.edited_at or created_at

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
    -- Try entry_id based path — not directly available, fall back
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

--- Group a flat list of Arcanum review comments into parley.Discussion[].
---
--- Grouping rules:
---   • A comment with reply_to_id == nil/0 is a root → new Discussion.
---   • A comment with reply_to_id belongs to the Discussion whose root
---     comment has that id.
---
--- @param comments  table[]  Raw Arcanum comment objects (ordered)
--- @param viewer    string   Authenticated viewer's login
--- @return parley.Discussion[]
function M.group_comments_into_discussions(comments, viewer)
  --- @type table<string, parley.Discussion>
  local by_root = {}
  --- @type string[]  insertion-order list of root ids
  local order = {}

  for _, raw in ipairs(comments) do
    local reply_to = raw.reply_to_id
    local is_root = not reply_to or reply_to == vim.NIL or reply_to == 0

    local comment = M.map_comment(raw, viewer)

    if is_root then
      local root_id = tostring(raw.id)

      local path, line, end_line = M.extract_anchor_location(raw.anchor)

      -- Skip comments without file anchor (PR-level general comments)
      if not path or not line then
        dbg.trace(
          "arcanum.mapping",
          "group_comments_into_discussions: skipping comment without file anchor id=" .. root_id
        )
        -- Still add as a discussion so it can be displayed; use placeholder location
        path = path or ""
        line = line or 0
      end

      -- resolved = issue_status is "resolved"
      local resolved = (raw.issue_status == "resolved")

      local disc = model.new_discussion({
        id = root_id,
        file = path,
        line = line,
        end_line = end_line,
        resolved = resolved,
        comments = { comment },
      })
      by_root[root_id] = disc
      table.insert(order, root_id)
    else
      local root_id = tostring(reply_to)
      local disc = by_root[root_id]
      if disc then
        table.insert(disc.comments, comment)
      end
      -- If root not yet seen, skip (shouldn't happen with server ordering).
    end
  end

  local result = {}
  for _, root_id in ipairs(order) do
    table.insert(result, by_root[root_id])
  end
  return result
end

--- Map a minimal or full Arcanum PR object to a parley.PR.
---
--- @param raw    table   Raw PR object (MinimalPullRequestDto or Public_PullRequest)
--- @return parley.PR
function M.map_pr(raw)
  local status = raw.status or "unknown"
  local review_status = M.PR_STATUS_MAP[status] or "pending"

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
