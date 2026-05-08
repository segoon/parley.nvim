--- Tests for parley.model — Discussion data model.
--- Run via: make test

local model = require("parley.model")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Apply overrides and optional key removals to a base table.
--- Lua silently drops nil values in table constructors (`{k = nil}` is an
--- empty table), so callers that want to omit a required field must pass the
--- key name in the `remove` list instead.
---@param base  table
---@param overrides table|nil  key→value pairs to set
---@param remove    string[]|nil  keys to explicitly set to nil
---@return table
local function apply(base, overrides, remove)
  if overrides then
    for k, v in pairs(overrides) do
      base[k] = v
    end
  end
  if remove then
    for _, k in ipairs(remove) do
      base[k] = nil
    end
  end
  return base
end

--- Build a minimal valid Comment table (no assertions exercised here).
---@param overrides table|nil
---@param remove    string[]|nil
---@return parley.Comment
local function make_comment(overrides, remove)
  local base = apply({
    id = "c1",
    author = "alice",
    body = model.new_body({ text = "hello", format = "markdown" }),
    created_at = "2024-01-01T00:00:00Z",
    updated_at = "2024-01-01T00:00:00Z",
  }, overrides, remove)
  return model.new_comment(base)
end

--- Build a minimal valid Discussion table.
---@param overrides table|nil
---@param remove    string[]|nil
---@return parley.Discussion
local function make_discussion(overrides, remove)
  local base = apply({
    id = "d1",
    file = "src/foo.lua",
    line = 10,
    comments = { make_comment() },
  }, overrides, remove)
  return model.new_discussion(base)
end

--- Build a minimal valid PR table.
---@param overrides table|nil
---@param remove    string[]|nil
---@return parley.PR
local function make_pr(overrides, remove)
  local base = apply({
    id = "42",
    title = "Fix the thing",
    state = "open",
    base_branch = "main",
    head_branch = "fix/thing",
    author = "alice",
    url = "https://github.com/org/repo/pull/42",
    review_status = "pending",
  }, overrides, remove)
  return model.new_pr(base)
end

-- ---------------------------------------------------------------------------
-- new_body
-- ---------------------------------------------------------------------------

describe("parley.model.new_body", function()
  it("stores text and format", function()
    local b = model.new_body({ text = "# Hello", format = "markdown" })
    assert.equals("# Hello", b.text)
    assert.equals("markdown", b.format)
  end)

  it("accepts plaintext format", function()
    local b = model.new_body({ text = "plain", format = "plaintext" })
    assert.equals("plaintext", b.format)
  end)

  it("asserts on missing text", function()
    assert.has_error(function()
      model.new_body({ format = "markdown" })
    end)
  end)

  it("asserts on missing format", function()
    assert.has_error(function()
      model.new_body({ text = "hi" })
    end)
  end)

  it("asserts on unknown format value", function()
    assert.has_error(function()
      model.new_body({ text = "hi", format = "html" })
    end)
  end)
end)

-- ---------------------------------------------------------------------------
-- new_reaction
-- ---------------------------------------------------------------------------

describe("parley.model.new_reaction", function()
  it("stores all fields", function()
    local r = model.new_reaction({ type = "+1", count = 3, viewer_reacted = true })
    assert.equals("+1", r.type)
    assert.equals(3, r.count)
    assert.is_true(r.viewer_reacted)
  end)

  it("asserts on missing type", function()
    assert.has_error(function()
      model.new_reaction({ count = 1, viewer_reacted = false })
    end)
  end)

  it("asserts on missing count", function()
    assert.has_error(function()
      model.new_reaction({ type = "+1", viewer_reacted = false })
    end)
  end)

  it("asserts on missing viewer_reacted", function()
    assert.has_error(function()
      model.new_reaction({ type = "+1", count = 1 })
    end)
  end)
end)

-- ---------------------------------------------------------------------------
-- new_comment
-- ---------------------------------------------------------------------------

describe("parley.model.new_comment", function()
  it("stores required fields", function()
    local c = make_comment()
    assert.equals("c1", c.id)
    assert.equals("alice", c.author)
    assert.equals("hello", c.body.text)
    assert.equals("2024-01-01T00:00:00Z", c.created_at)
    assert.equals("2024-01-01T00:00:00Z", c.updated_at)
  end)

  it("defaults reactions to empty table", function()
    local c = make_comment()
    assert.same({}, c.reactions)
  end)

  it("defaults is_own to false", function()
    local c = make_comment()
    assert.is_false(c.is_own)
  end)

  it("defaults parent_comment_id to nil", function()
    local c = make_comment()
    assert.is_nil(c.parent_comment_id)
  end)

  it("accepts explicit reactions list", function()
    local r = model.new_reaction({ type = "heart", count = 2, viewer_reacted = false })
    local c = make_comment({ reactions = { r } })
    assert.equals(1, #c.reactions)
    assert.equals("heart", c.reactions[1].type)
  end)

  it("accepts is_own = true", function()
    local c = make_comment({ is_own = true })
    assert.is_true(c.is_own)
  end)

  it("accepts non-nil parent_comment_id", function()
    local c = make_comment({ parent_comment_id = "c0" })
    assert.equals("c0", c.parent_comment_id)
  end)

  it("asserts on missing id", function()
    assert.has_error(function()
      make_comment(nil, { "id" })
    end)
  end)

  it("asserts on missing author", function()
    assert.has_error(function()
      make_comment(nil, { "author" })
    end)
  end)

  it("asserts on missing body", function()
    assert.has_error(function()
      make_comment(nil, { "body" })
    end)
  end)

  it("asserts on missing created_at", function()
    assert.has_error(function()
      make_comment(nil, { "created_at" })
    end)
  end)

  it("asserts on missing updated_at", function()
    assert.has_error(function()
      make_comment(nil, { "updated_at" })
    end)
  end)
end)

-- ---------------------------------------------------------------------------
-- new_discussion
-- ---------------------------------------------------------------------------

describe("parley.model.new_discussion", function()
  it("stores required fields", function()
    local d = make_discussion()
    assert.equals("d1", d.id)
    assert.equals("src/foo.lua", d.file)
    assert.equals(10, d.line)
    assert.equals(1, #d.comments)
  end)

  it("defaults resolved to false", function()
    local d = make_discussion()
    assert.is_false(d.resolved)
  end)

  it("defaults end_line to nil", function()
    local d = make_discussion()
    assert.is_nil(d.end_line)
  end)

  it("accepts resolved = true", function()
    local d = make_discussion({ resolved = true })
    assert.is_true(d.resolved)
  end)

  it("accepts explicit end_line", function()
    local d = make_discussion({ end_line = 15 })
    assert.equals(15, d.end_line)
  end)

  it("asserts on missing id", function()
    assert.has_error(function()
      make_discussion(nil, { "id" })
    end)
  end)

  it("asserts on missing file", function()
    assert.has_error(function()
      make_discussion(nil, { "file" })
    end)
  end)

  it("asserts on missing line", function()
    assert.has_error(function()
      make_discussion(nil, { "line" })
    end)
  end)

  it("asserts on missing comments", function()
    assert.has_error(function()
      make_discussion(nil, { "comments" })
    end)
  end)
end)

-- ---------------------------------------------------------------------------
-- new_pr
-- ---------------------------------------------------------------------------

describe("parley.model.new_pr", function()
  it("stores all fields", function()
    local pr = make_pr()
    assert.equals("42", pr.id)
    assert.equals("Fix the thing", pr.title)
    assert.equals("open", pr.state)
    assert.equals("main", pr.base_branch)
    assert.equals("fix/thing", pr.head_branch)
    assert.equals("alice", pr.author)
    assert.equals("https://github.com/org/repo/pull/42", pr.url)
    assert.equals("pending", pr.review_status)
  end)

  it("accepts all valid review_status values", function()
    local statuses = { "approved", "changes_requested", "pending", "dismissed", "commented" }
    for _, s in ipairs(statuses) do
      local pr = make_pr({ review_status = s })
      assert.equals(s, pr.review_status)
    end
  end)

  it("asserts on unknown review_status", function()
    assert.has_error(function()
      make_pr({ review_status = "superapproved" })
    end)
  end)

  it("asserts on missing id", function()
    assert.has_error(function()
      make_pr(nil, { "id" })
    end)
  end)

  it("asserts on missing title", function()
    assert.has_error(function()
      make_pr(nil, { "title" })
    end)
  end)

  it("asserts on missing state", function()
    assert.has_error(function()
      make_pr(nil, { "state" })
    end)
  end)

  it("asserts on missing base_branch", function()
    assert.has_error(function()
      make_pr(nil, { "base_branch" })
    end)
  end)

  it("asserts on missing head_branch", function()
    assert.has_error(function()
      make_pr(nil, { "head_branch" })
    end)
  end)

  it("asserts on missing author", function()
    assert.has_error(function()
      make_pr(nil, { "author" })
    end)
  end)

  it("asserts on missing url", function()
    assert.has_error(function()
      make_pr(nil, { "url" })
    end)
  end)

  it("asserts on missing review_status", function()
    assert.has_error(function()
      make_pr(nil, { "review_status" })
    end)
  end)
end)

-- ---------------------------------------------------------------------------
-- is_resolved
-- ---------------------------------------------------------------------------

describe("parley.model.is_resolved", function()
  it("returns false for an unresolved discussion", function()
    local d = make_discussion({ resolved = false })
    assert.is_false(model.is_resolved(d))
  end)

  it("returns true for a resolved discussion", function()
    local d = make_discussion({ resolved = true })
    assert.is_true(model.is_resolved(d))
  end)
end)

-- ---------------------------------------------------------------------------
-- first_comment
-- ---------------------------------------------------------------------------

describe("parley.model.first_comment", function()
  it("returns the first comment when list is non-empty", function()
    local c1 = make_comment({ id = "c1" })
    local c2 = make_comment({ id = "c2" })
    local d = make_discussion({ comments = { c1, c2 } })
    assert.equals("c1", model.first_comment(d).id)
  end)

  it("returns nil when comments list is empty", function()
    local d = make_discussion({ comments = {} })
    assert.is_nil(model.first_comment(d))
  end)
end)

-- ---------------------------------------------------------------------------
-- comment_count
-- ---------------------------------------------------------------------------

describe("parley.model.comment_count", function()
  it("returns 0 for an empty comments list", function()
    local d = make_discussion({ comments = {} })
    assert.equals(0, model.comment_count(d))
  end)

  it("returns the correct count", function()
    local d = make_discussion({ comments = { make_comment(), make_comment() } })
    assert.equals(2, model.comment_count(d))
  end)
end)

-- ---------------------------------------------------------------------------
-- is_reply
-- ---------------------------------------------------------------------------

describe("parley.model.is_reply", function()
  it("returns false when parent_comment_id is nil", function()
    local c = make_comment({ parent_comment_id = nil })
    assert.is_false(model.is_reply(c))
  end)

  it("returns true when parent_comment_id is set", function()
    local c = make_comment({ parent_comment_id = "c0" })
    assert.is_true(model.is_reply(c))
  end)
end)

-- ---------------------------------------------------------------------------
-- is_markdown
-- ---------------------------------------------------------------------------

describe("parley.model.is_markdown", function()
  it("returns true for a markdown body", function()
    local b = model.new_body({ text = "# hi", format = "markdown" })
    assert.is_true(model.is_markdown(b))
  end)

  it("returns false for a plaintext body", function()
    local b = model.new_body({ text = "hi", format = "plaintext" })
    assert.is_false(model.is_markdown(b))
  end)
end)
