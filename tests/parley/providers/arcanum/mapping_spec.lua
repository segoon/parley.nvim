--- Tests for parley.providers.arcanum.mapping — API response mapping.
--- Run via: make test

local mapping = require("parley.providers.arcanum.mapping")

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

--- Build a minimal Arcanum comment object with the given fields.
--- Special sentinel: use the string "__nil__" as a value to explicitly set
--- a field to nil (since Lua tables cannot store nil via pairs iteration).
--- @param overrides table
--- @return table
local NIL_SENTINEL = "__nil__"
local function make_raw_comment(overrides)
  local base = {
    id = 100,
    user = { name = "alice", uid = "123" },
    content = "Hello world",
    created_at = "2024-01-01T10:00:00Z",
    updated_at = "2024-01-01T10:00:00Z",
    reply_to_id = vim.NIL,
    reactions = {},
    issue_status = "not_issue",
    anchor = nil,
  }
  if overrides then
    for k, v in pairs(overrides) do
      if v == NIL_SENTINEL then
        base[k] = nil
      else
        base[k] = v
      end
    end
  end
  return base
end

--- Build a minimal anchor with file position.
--- @param path string
--- @param line integer
--- @param size? integer
--- @return table
local function make_anchor(path, line, size)
  return {
    review_request = {
      id = 1,
      diff = {
        diff_set_xid = "xid-123",
        file = {
          path = path,
          position = {
            line = line,
            size = size or 1,
            side = "new",
          },
        },
      },
    },
  }
end

-- ---------------------------------------------------------------------------
-- Suite: map_reactions
-- ---------------------------------------------------------------------------

describe("parley.providers.arcanum.mapping — map_reactions", function()
  it("returns empty list for nil reactions", function()
    local result = mapping.map_reactions(nil, "viewer")
    assert.same({}, result)
  end)

  it("returns empty list for empty reactions array", function()
    local result = mapping.map_reactions({}, "viewer")
    assert.same({}, result)
  end)

  it("aggregates reactions by code", function()
    local reactions = {
      { id = 1, code = "+1", user = { name = "alice" } },
      { id = 2, code = "+1", user = { name = "bob" } },
      { id = 3, code = "heart", user = { name = "carol" } },
    }
    local result = mapping.map_reactions(reactions, "")

    -- Find +1 reaction
    local thumbs_up = nil
    local heart = nil
    for _, r in ipairs(result) do
      if r.type == "+1" then
        thumbs_up = r
      elseif r.type == "heart" then
        heart = r
      end
    end

    assert.is_not_nil(thumbs_up)
    assert.equals(2, thumbs_up.count)
    assert.is_not_nil(heart)
    assert.equals(1, heart.count)
  end)

  it("sets viewer_reacted=true when viewer login matches", function()
    local reactions = {
      { id = 1, code = "+1", user = { name = "alice" } },
      { id = 2, code = "+1", user = { name = "viewer" } },
    }
    local result = mapping.map_reactions(reactions, "viewer")

    local thumbs_up = nil
    for _, r in ipairs(result) do
      if r.type == "+1" then
        thumbs_up = r
      end
    end

    assert.is_not_nil(thumbs_up)
    assert.is_true(thumbs_up.viewer_reacted)
  end)

  it("sets viewer_reacted=false when viewer has not reacted", function()
    local reactions = {
      { id = 1, code = "+1", user = { name = "alice" } },
    }
    local result = mapping.map_reactions(reactions, "viewer")

    assert.is_false(result[1].viewer_reacted)
  end)

  it("skips reactions with empty or nil code", function()
    local reactions = {
      { id = 1, code = "", user = { name = "alice" } },
      { id = 2, code = nil, user = { name = "bob" } },
      { id = 3, code = "+1", user = { name = "carol" } },
    }
    local result = mapping.map_reactions(reactions, "")

    assert.equals(1, #result)
    assert.equals("+1", result[1].type)
  end)
end)

-- ---------------------------------------------------------------------------
-- Suite: map_comment
-- ---------------------------------------------------------------------------

describe("parley.providers.arcanum.mapping — map_comment", function()
  it("maps id as string", function()
    local raw = make_raw_comment({ id = 42 })
    local comment = mapping.map_comment(raw, "")
    assert.equals("42", comment.id)
  end)

  it("maps author from user.name field (v1)", function()
    local raw = make_raw_comment({ user = { name = "bob", uid = "456" } })
    local comment = mapping.map_comment(raw, "")
    assert.equals("bob", comment.author)
  end)

  it("maps author from author.name field (v2/PublicCommentDto)", function()
    local raw = make_raw_comment({ user = NIL_SENTINEL, author = { name = "carol" } })
    local comment = mapping.map_comment(raw, "")
    assert.equals("carol", comment.author)
  end)

  it("maps content to body.text as markdown", function()
    local raw = make_raw_comment({ content = "My comment" })
    local comment = mapping.map_comment(raw, "")
    assert.equals("My comment", comment.body.text)
    assert.equals("markdown", comment.body.format)
  end)

  it("maps created_at and updated_at", function()
    local raw = make_raw_comment({
      created_at = "2024-01-01T10:00:00Z",
      updated_at = "2024-01-02T10:00:00Z",
    })
    local comment = mapping.map_comment(raw, "")
    assert.equals("2024-01-01T10:00:00Z", comment.created_at)
    assert.equals("2024-01-02T10:00:00Z", comment.updated_at)
  end)

  it("sets parent_comment_id=nil for root comments (reply_to_id is NIL)", function()
    local raw = make_raw_comment({ reply_to_id = vim.NIL })
    local comment = mapping.map_comment(raw, "")
    assert.is_nil(comment.parent_comment_id)
  end)

  it("sets parent_comment_id=nil for reply_to_id=0", function()
    local raw = make_raw_comment({ reply_to_id = 0 })
    local comment = mapping.map_comment(raw, "")
    assert.is_nil(comment.parent_comment_id)
  end)

  it("sets parent_comment_id as string for replies", function()
    local raw = make_raw_comment({ reply_to_id = 999 })
    local comment = mapping.map_comment(raw, "")
    assert.equals("999", comment.parent_comment_id)
  end)

  it("sets is_own=true when author matches viewer", function()
    local raw = make_raw_comment({ user = { name = "alice" } })
    local comment = mapping.map_comment(raw, "alice")
    assert.is_true(comment.is_own)
  end)

  it("sets is_own=false when author does not match viewer", function()
    local raw = make_raw_comment({ user = { name = "alice" } })
    local comment = mapping.map_comment(raw, "bob")
    assert.is_false(comment.is_own)
  end)

  it("sets is_own=false for empty viewer", function()
    local raw = make_raw_comment({ user = { name = "alice" } })
    local comment = mapping.map_comment(raw, "")
    assert.is_false(comment.is_own)
  end)
end)

-- ---------------------------------------------------------------------------
-- Suite: extract_anchor_location
-- ---------------------------------------------------------------------------

describe("parley.providers.arcanum.mapping — extract_anchor_location", function()
  it("returns nil,nil,nil for nil anchor", function()
    local path, line, end_line = mapping.extract_anchor_location(nil)
    assert.is_nil(path)
    assert.is_nil(line)
    assert.is_nil(end_line)
  end)

  it("returns nil,nil,nil when anchor has no review_request", function()
    local path, line, end_line = mapping.extract_anchor_location({ commit = {} })
    assert.is_nil(path)
    assert.is_nil(line)
    assert.is_nil(end_line)
  end)

  it("extracts path and line from well-formed anchor", function()
    local anchor = make_anchor("src/foo.lua", 42)
    local path, line, end_line = mapping.extract_anchor_location(anchor)
    assert.equals("src/foo.lua", path)
    assert.equals(42, line)
    assert.is_nil(end_line)
  end)

  it("computes end_line from size>1", function()
    local anchor = make_anchor("src/foo.lua", 10, 3)
    local path, line, end_line = mapping.extract_anchor_location(anchor)
    assert.equals("src/foo.lua", path)
    assert.equals(10, line)
    assert.equals(12, end_line) -- 10 + 3 - 1
  end)

  it("end_line is nil for size=1", function()
    local anchor = make_anchor("src/foo.lua", 5, 1)
    local _, _, end_line = mapping.extract_anchor_location(anchor)
    assert.is_nil(end_line)
  end)
end)

-- ---------------------------------------------------------------------------
-- Suite: group_comments_into_discussions
-- ---------------------------------------------------------------------------

describe("parley.providers.arcanum.mapping — group_comments_into_discussions", function()
  it("returns empty list for empty input", function()
    local result = mapping.group_comments_into_discussions({}, "viewer")
    assert.same({}, result)
  end)

  it("creates one discussion per root comment", function()
    local comments = {
      make_raw_comment({ id = 1, anchor = make_anchor("a.lua", 1), reply_to_id = vim.NIL }),
      make_raw_comment({ id = 2, anchor = make_anchor("b.lua", 5), reply_to_id = vim.NIL }),
    }
    local result = mapping.group_comments_into_discussions(comments, "")
    assert.equals(2, #result)
  end)

  it("groups replies under their root discussion", function()
    local comments = {
      make_raw_comment({ id = 10, anchor = make_anchor("f.lua", 3), reply_to_id = vim.NIL }),
      make_raw_comment({ id = 11, reply_to_id = 10 }),
      make_raw_comment({ id = 12, reply_to_id = 10 }),
    }
    local result = mapping.group_comments_into_discussions(comments, "")
    assert.equals(1, #result)
    assert.equals(3, #result[1].comments)
  end)

  it("discussion id equals root comment id as string", function()
    local comments = {
      make_raw_comment({ id = 42, anchor = make_anchor("f.lua", 1), reply_to_id = vim.NIL }),
    }
    local result = mapping.group_comments_into_discussions(comments, "")
    assert.equals("42", result[1].id)
  end)

  it("maps file path from anchor", function()
    local comments = {
      make_raw_comment({ id = 1, anchor = make_anchor("src/bar.lua", 7), reply_to_id = vim.NIL }),
    }
    local result = mapping.group_comments_into_discussions(comments, "")
    assert.equals("src/bar.lua", result[1].file)
  end)

  it("maps line from anchor position", function()
    local comments = {
      make_raw_comment({ id = 1, anchor = make_anchor("f.lua", 15), reply_to_id = vim.NIL }),
    }
    local result = mapping.group_comments_into_discussions(comments, "")
    assert.equals(15, result[1].line)
  end)

  it("resolved=true when issue_status='resolved'", function()
    local comments = {
      make_raw_comment({ id = 1, anchor = make_anchor("f.lua", 1), reply_to_id = vim.NIL, issue_status = "resolved" }),
    }
    local result = mapping.group_comments_into_discussions(comments, "")
    assert.is_true(result[1].resolved)
  end)

  it("resolved=false when issue_status='open'", function()
    local comments = {
      make_raw_comment({ id = 1, anchor = make_anchor("f.lua", 1), reply_to_id = vim.NIL, issue_status = "open" }),
    }
    local result = mapping.group_comments_into_discussions(comments, "")
    assert.is_false(result[1].resolved)
  end)

  it("preserves insertion order", function()
    local comments = {
      make_raw_comment({ id = 3, anchor = make_anchor("a.lua", 1), reply_to_id = vim.NIL }),
      make_raw_comment({ id = 1, anchor = make_anchor("b.lua", 2), reply_to_id = vim.NIL }),
      make_raw_comment({ id = 2, anchor = make_anchor("c.lua", 3), reply_to_id = vim.NIL }),
    }
    local result = mapping.group_comments_into_discussions(comments, "")
    assert.equals("3", result[1].id)
    assert.equals("1", result[2].id)
    assert.equals("2", result[3].id)
  end)
end)

-- ---------------------------------------------------------------------------
-- Suite: map_pr
-- ---------------------------------------------------------------------------

describe("parley.providers.arcanum.mapping — map_pr", function()
  it("maps id as string", function()
    local raw = { id = 123, summary = "My PR", status = "open", vcs = {}, author = "user", url = "" }
    local pr = mapping.map_pr(raw)
    assert.equals("123", pr.id)
  end)

  it("maps summary to title", function()
    local raw = { id = 1, summary = "Fix the bug", status = "open", vcs = {}, author = "user", url = "" }
    local pr = mapping.map_pr(raw)
    assert.equals("Fix the bug", pr.title)
  end)

  it("maps vcs.from_branch to head_branch", function()
    local raw = {
      id = 1,
      summary = "",
      status = "open",
      vcs = { from_branch = "users/alice/feature", to_branch = "trunk" },
      author = "alice",
      url = "",
    }
    local pr = mapping.map_pr(raw)
    assert.equals("users/alice/feature", pr.head_branch)
    assert.equals("trunk", pr.base_branch)
  end)

  it("maps author.name from object", function()
    local raw = {
      id = 1,
      summary = "",
      status = "open",
      vcs = {},
      author = { name = "alice" },
      url = "",
    }
    local pr = mapping.map_pr(raw)
    assert.equals("alice", pr.author)
  end)

  it("maps author string directly", function()
    local raw = { id = 1, summary = "", status = "open", vcs = {}, author = "bob", url = "" }
    local pr = mapping.map_pr(raw)
    assert.equals("bob", pr.author)
  end)

  it("maps 'merged' status to review_status='approved'", function()
    local raw = { id = 1, summary = "", status = "merged", vcs = {}, author = "", url = "" }
    local pr = mapping.map_pr(raw)
    assert.equals("approved", pr.review_status)
  end)

  it("maps 'discarded' status to review_status='dismissed'", function()
    local raw = { id = 1, summary = "", status = "discarded", vcs = {}, author = "", url = "" }
    local pr = mapping.map_pr(raw)
    assert.equals("dismissed", pr.review_status)
  end)

  it("maps 'open' status to review_status='pending'", function()
    local raw = { id = 1, summary = "", status = "open", vcs = {}, author = "", url = "" }
    local pr = mapping.map_pr(raw)
    assert.equals("pending", pr.review_status)
  end)

  it("maps unknown status to review_status='pending'", function()
    local raw = { id = 1, summary = "", status = "unknown", vcs = {}, author = "", url = "" }
    local pr = mapping.map_pr(raw)
    assert.equals("pending", pr.review_status)
  end)
end)
