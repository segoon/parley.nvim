local optional_methods = { "begin_reply", "begin_post_top_level_comment", "reaction_choices", "reaction_presentation" }
--- Tests for parley.provider (interface contract) and parley.mock_provider.
--- Run via: make test

local provider = require("parley.provider")
local mock_provider = require("parley.mock_provider")
local model = require("parley.model")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Build a minimal valid PR.
---@return parley.PR
local function make_pr()
  return model.new_pr({
    id = "42",
    title = "Fix the thing",
    state = "open",
    base_branch = "main",
    head_branch = "fix/thing",
    author = "alice",
    url = "https://github.com/org/repo/pull/42",
    review_status = "pending",
  })
end

---@param pr parley.PR
---@return parley.DetectedReview
local function make_review(pr)
  return {
    pr = pr,
    head_sha = "deadbeef",
    write_context = { number = tonumber(pr.id), head_sha = "deadbeef" },
  }
end

---@param start_line integer
---@param end_line integer|nil
---@return parley.Anchor
local function make_anchor(start_line, end_line)
  return { start_line = start_line, end_line = end_line }
end

--- Build a minimal valid Comment.
---@param overrides table|nil
---@return parley.Comment
local function make_comment(overrides)
  local opts = vim.tbl_extend("force", {
    id = "c1",
    author = "alice",
    body = model.new_body({ text = "hello", format = "markdown" }),
    created_at = "2024-01-01T00:00:00Z",
    updated_at = "2024-01-01T00:00:00Z",
  }, overrides or {})
  return model.new_comment(opts)
end

--- Build a minimal valid Discussion.
---@param overrides table|nil
---@return parley.Discussion
local function make_discussion(overrides)
  local opts = vim.tbl_extend("force", {
    id = "d1",
    file = "src/foo.lua",
    line = 10,
    comments = { make_comment() },
  }, overrides or {})
  return model.new_discussion(opts)
end

-- ---------------------------------------------------------------------------
-- provider.validate
-- ---------------------------------------------------------------------------

describe("parley.provider.validate", function()
  for _, name in ipairs(optional_methods) do
    it("validates optional method " .. name, function()
      local p = mock_provider.new({})
      p[name] = nil
      assert.is_true(provider.validate(p))
      p[name] = function() end
      assert.is_true(provider.validate(p))
      for _, value in ipairs({ false, true, 42, "method", {} }) do
        p[name] = value
        assert.is_false(provider.validate(p))
      end
    end)
  end

  it("requires a nonblank display name", function()
    local p = mock_provider.new({})
    for _, value in ipairs({ false, 42, {}, "", " \t\n" }) do
      p.display_name = value
      assert.is_false(provider.validate(p))
    end
    p.display_name = nil
    assert.is_false(provider.validate(p))
    p.display_name = "Custom Host"
    assert.is_true(provider.validate(p))
  end)

  it("accepts a table that implements all required methods", function()
    local p = mock_provider.new({})
    assert.is_true(provider.validate(p))
  end)

  it("rejects nil", function()
    assert.is_false(provider.validate(nil))
  end)

  it("rejects a non-table value", function()
    assert.is_false(provider.validate("not a provider"))
  end)

  it("rejects a table missing auth", function()
    local p = mock_provider.new({})
    p.auth = nil
    assert.is_false(provider.validate(p))
  end)

  it("rejects a table missing detect_pr", function()
    local p = mock_provider.new({})
    p.detect_pr = nil
    assert.is_false(provider.validate(p))
  end)

  it("rejects a table missing fetch_discussions", function()
    local p = mock_provider.new({})
    p.fetch_discussions = nil
    assert.is_false(provider.validate(p))
  end)

  it("rejects a table missing post_top_level_comment", function()
    local p = mock_provider.new({})
    p.post_top_level_comment = nil
    assert.is_false(provider.validate(p))
  end)

  it("rejects a table missing reply", function()
    local p = mock_provider.new({})
    p.reply = nil
    assert.is_false(provider.validate(p))
  end)

  it("rejects a table missing resolve", function()
    local p = mock_provider.new({})
    p.resolve = nil
    assert.is_false(provider.validate(p))
  end)

  it("rejects a table missing unresolve", function()
    local p = mock_provider.new({})
    p.unresolve = nil
    assert.is_false(provider.validate(p))
  end)

  it("rejects a table missing react", function()
    local p = mock_provider.new({})
    p.react = nil
    assert.is_false(provider.validate(p))
  end)

  it("rejects a table missing edit", function()
    local p = mock_provider.new({})
    p.edit = nil
    assert.is_false(provider.validate(p))
  end)

  it("rejects a table missing delete", function()
    local p = mock_provider.new({})
    p.delete = nil
    assert.is_false(provider.validate(p))
  end)

  it("rejects a table missing submit_review", function()
    local p = mock_provider.new({})
    p.submit_review = nil
    assert.is_false(provider.validate(p))
  end)

  it("rejects a table where a method is not a function", function()
    local p = mock_provider.new({})
    p.auth = "not a function"
    assert.is_false(provider.validate(p))
  end)
end)

-- ---------------------------------------------------------------------------
-- mock_provider.new — initial state
-- ---------------------------------------------------------------------------

describe("parley.mock_provider.new", function()
  it("returns a table that passes validate", function()
    local p = mock_provider.new({})
    assert.is_true(provider.validate(p))
  end)

  it("starts with an empty calls table", function()
    local p = mock_provider.new({})
    for _, name in ipairs(provider.METHOD_NAMES) do
      assert.same({}, p.calls[name])
    end
  end)
end)

-- ---------------------------------------------------------------------------
-- auth
-- ---------------------------------------------------------------------------

describe("parley.mock_provider auth", function()
  it("returns the configured token", function()
    local p = mock_provider.new({ token = "mytoken" })
    assert.equals("mytoken", p:auth())
  end)

  it("records the call", function()
    local p = mock_provider.new({ token = "t" })
    p:auth()
    assert.equals(1, #p.calls.auth)
  end)

  it("errors when configured to do so", function()
    local p = mock_provider.new({})
    p:set_error("auth", "auth failed")
    assert.has_error(function()
      p:auth()
    end, "auth failed")
  end)
end)

-- ---------------------------------------------------------------------------
-- detect_pr
-- ---------------------------------------------------------------------------

describe("parley.mock_provider detect_pr", function()
  it("returns the configured PR", function()
    local pr = make_pr()
    local p = mock_provider.new({ pr = pr })
    local result = p:detect_pr("/repo", "fix/thing")
    assert.equals(pr.id, result.pr.id)
  end)

  it("returns nil when no PR is configured", function()
    local p = mock_provider.new({})
    local result = p:detect_pr("/repo", "main")
    assert.is_nil(result)
  end)

  it("records the call with repo_root and branch", function()
    local p = mock_provider.new({})
    p:detect_pr("/my/repo", "feature/x")
    assert.equals(1, #p.calls.detect_pr)
    assert.equals("/my/repo", p.calls.detect_pr[1].repo_root)
    assert.equals("feature/x", p.calls.detect_pr[1].branch)
  end)

  it("errors when configured to do so", function()
    local p = mock_provider.new({})
    p:set_error("detect_pr", "network error")
    assert.has_error(function()
      p:detect_pr("/repo", "main")
    end, "network error")
  end)
end)

-- ---------------------------------------------------------------------------
-- fetch_discussions
-- ---------------------------------------------------------------------------

describe("parley.mock_provider fetch_discussions", function()
  it("returns the configured discussions", function()
    local d = make_discussion()
    local review = make_review(make_pr())
    local p = mock_provider.new({ discussions = { d } })
    local result = p:fetch_discussions(review)
    assert.equals(1, #result)
    assert.equals(d.id, result[1].id)
  end)

  it("returns empty list when no discussions are configured", function()
    local review = make_review(make_pr())
    local p = mock_provider.new({})
    local result = p:fetch_discussions(review)
    assert.same({}, result)
  end)

  it("records the call with pr", function()
    local review = make_review(make_pr())
    local p = mock_provider.new({})
    p:fetch_discussions(review)
    assert.equals(1, #p.calls.fetch_discussions)
    assert.equals(review.pr.id, p.calls.fetch_discussions[1].pr.id)
  end)

  it("errors when configured to do so", function()
    local review = make_review(make_pr())
    local p = mock_provider.new({})
    p:set_error("fetch_discussions", "rate limited")
    assert.has_error(function()
      p:fetch_discussions(review)
    end, "rate limited")
  end)
end)

-- ---------------------------------------------------------------------------
-- post_top_level_comment
-- ---------------------------------------------------------------------------

describe("parley.mock_provider post_top_level_comment", function()
  it("returns a new Comment", function()
    local review = make_review(make_pr())
    local body = model.new_body({ text = "new comment", format = "markdown" })
    local p = mock_provider.new({})
    local comment = p:post_top_level_comment(review, "src/foo.lua", make_anchor(10), body)
    assert.equals("string", type(comment.id))
    assert.equals("new comment", comment.body.text)
  end)

  it("creates a new Discussion anchored to the given file and line", function()
    local review = make_review(make_pr())
    local body = model.new_body({ text = "first", format = "markdown" })
    local p = mock_provider.new({})
    p:post_top_level_comment(review, "src/bar.lua", make_anchor(5), body)
    local discussions = p:fetch_discussions(review)
    assert.equals(1, #discussions)
    assert.equals("src/bar.lua", discussions[1].file)
    assert.equals(5, discussions[1].line)
    assert.equals(1, #discussions[1].comments)
  end)

  it("records the call", function()
    local review = make_review(make_pr())
    local body = model.new_body({ text = "x", format = "markdown" })
    local p = mock_provider.new({})
    p:post_top_level_comment(review, "file.lua", make_anchor(1), body)
    assert.equals(1, #p.calls.post_top_level_comment)
    local c = p.calls.post_top_level_comment[1]
    assert.equals(review.pr.id, c.pr.id)
    assert.equals("file.lua", c.file)
    assert.same(make_anchor(1), c.anchor)
    assert.equals("x", c.body.text)
  end)

  it("errors when configured to do so", function()
    local review = make_review(make_pr())
    local body = model.new_body({ text = "x", format = "markdown" })
    local p = mock_provider.new({})
    p:set_error("post_top_level_comment", "forbidden")
    assert.has_error(function()
      p:post_top_level_comment(review, "file.lua", make_anchor(1), body)
    end, "forbidden")
  end)

  it("stores anchor end_line", function()
    local review = make_review(make_pr())
    local body = model.new_body({ text = "range", format = "markdown" })
    local p = mock_provider.new({})
    p:post_top_level_comment(review, "src/foo.lua", make_anchor(5, 8), body)

    local discussions = p:fetch_discussions(review)
    assert.equals(5, discussions[1].line)
    assert.equals(8, discussions[1].end_line)
  end)
end)

-- ---------------------------------------------------------------------------
-- reply
-- ---------------------------------------------------------------------------

describe("parley.mock_provider reply", function()
  it("returns a new Comment appended to the existing Discussion", function()
    local d = make_discussion({ id = "d1" })
    local review = make_review(make_pr())
    local p = mock_provider.new({ discussions = { d } })
    local body = model.new_body({ text = "my reply", format = "markdown" })
    local comment = p:reply(review, d, d.comments[1], body)
    assert.equals("my reply", comment.body.text)
    -- discussion should now have 2 comments
    local discussions = p:fetch_discussions(review)
    assert.equals(2, #discussions[1].comments)
  end)

  it("the reply comment has the root comment as parent", function()
    local root = make_comment({ id = "c1" })
    local d = make_discussion({ id = "d1", comments = { root } })
    local review = make_review(make_pr())
    local p = mock_provider.new({ discussions = { d } })
    local body = model.new_body({ text = "reply", format = "markdown" })
    local comment = p:reply(review, d, root, body)
    assert.equals("c1", comment.parent_comment_id)
  end)

  it("errors when discussion_id is not found", function()
    local review = make_review(make_pr())
    local p = mock_provider.new({})
    local body = model.new_body({ text = "reply", format = "markdown" })
    assert.has_error(function()
      p:reply(review, make_discussion({ id = "nonexistent" }), make_comment({ id = "c1" }), body)
    end)
  end)

  it("errors when parent_comment_id is not found", function()
    local d = make_discussion({ id = "d1" })
    local review = make_review(make_pr())
    local p = mock_provider.new({ discussions = { d } })
    local body = model.new_body({ text = "reply", format = "markdown" })
    assert.has_error(function()
      p:reply(review, d, make_comment({ id = "missing" }), body)
    end)
  end)

  it("records the call", function()
    local d = make_discussion({ id = "d1" })
    local review = make_review(make_pr())
    local p = mock_provider.new({ discussions = { d } })
    local body = model.new_body({ text = "r", format = "markdown" })
    p:reply(review, d, d.comments[1], body)
    assert.equals(1, #p.calls.reply)
    local c = p.calls.reply[1]
    assert.equals("d1", c.discussion.id)
    assert.equals("c1", c.parent_comment.id)
  end)

  it("errors when configured to do so", function()
    local d = make_discussion({ id = "d1" })
    local review = make_review(make_pr())
    local p = mock_provider.new({ discussions = { d } })
    p:set_error("reply", "server error")
    local body = model.new_body({ text = "r", format = "markdown" })
    assert.has_error(function()
      p:reply(review, d, d.comments[1], body)
    end, "server error")
  end)
end)

-- ---------------------------------------------------------------------------
-- resolve / unresolve
-- ---------------------------------------------------------------------------

describe("parley.mock_provider resolve", function()
  it("marks the discussion as resolved", function()
    local d = make_discussion({ id = "d1", resolved = false })
    local review = make_review(make_pr())
    local p = mock_provider.new({ discussions = { d } })
    p:resolve(review, "d1")
    local discussions = p:fetch_discussions(review)
    assert.is_true(discussions[1].resolved)
  end)

  it("errors when discussion_id is not found", function()
    local review = make_review(make_pr())
    local p = mock_provider.new({})
    assert.has_error(function()
      p:resolve(review, "missing")
    end)
  end)

  it("records the call", function()
    local d = make_discussion({ id = "d1" })
    local review = make_review(make_pr())
    local p = mock_provider.new({ discussions = { d } })
    p:resolve(review, "d1")
    assert.equals(1, #p.calls.resolve)
    assert.equals("d1", p.calls.resolve[1].discussion_id)
  end)

  it("errors when configured to do so", function()
    local d = make_discussion({ id = "d1" })
    local review = make_review(make_pr())
    local p = mock_provider.new({ discussions = { d } })
    p:set_error("resolve", "not allowed")
    assert.has_error(function()
      p:resolve(review, "d1")
    end, "not allowed")
  end)
end)

describe("parley.mock_provider unresolve", function()
  it("marks the discussion as unresolved", function()
    local d = make_discussion({ id = "d1", resolved = true })
    local review = make_review(make_pr())
    local p = mock_provider.new({ discussions = { d } })
    p:unresolve(review, "d1")
    local discussions = p:fetch_discussions(review)
    assert.is_false(discussions[1].resolved)
  end)

  it("errors when discussion_id is not found", function()
    local review = make_review(make_pr())
    local p = mock_provider.new({})
    assert.has_error(function()
      p:unresolve(review, "missing")
    end)
  end)

  it("records the call", function()
    local d = make_discussion({ id = "d1", resolved = true })
    local review = make_review(make_pr())
    local p = mock_provider.new({ discussions = { d } })
    p:unresolve(review, "d1")
    assert.equals(1, #p.calls.unresolve)
    assert.equals("d1", p.calls.unresolve[1].discussion_id)
  end)
end)

-- ---------------------------------------------------------------------------
-- react
-- ---------------------------------------------------------------------------

describe("parley.mock_provider react", function()
  it("adds a reaction to a comment that has none yet", function()
    local c = make_comment({ id = "c1", reactions = {} })
    local d = make_discussion({ id = "d1", comments = { c } })
    local review = make_review(make_pr())
    local p = mock_provider.new({ discussions = { d } })
    p:react(review, "c1", "+1")
    local discussions = p:fetch_discussions(review)
    local reactions = discussions[1].comments[1].reactions
    assert.equals(1, #reactions)
    assert.equals("+1", reactions[1].type)
    assert.equals(1, reactions[1].count)
    assert.is_true(reactions[1].viewer_reacted)
  end)

  it("increments count when another user already reacted", function()
    local existing = model.new_reaction({ type = "+1", count = 2, viewer_reacted = false })
    local c = make_comment({ id = "c1", reactions = { existing } })
    local d = make_discussion({ id = "d1", comments = { c } })
    local review = make_review(make_pr())
    local p = mock_provider.new({ discussions = { d } })
    p:react(review, "c1", "+1")
    local reactions = p:fetch_discussions(review)[1].comments[1].reactions
    assert.equals(3, reactions[1].count)
    assert.is_true(reactions[1].viewer_reacted)
  end)

  it("removes (toggles off) a reaction the viewer already reacted to", function()
    local existing = model.new_reaction({ type = "heart", count = 1, viewer_reacted = true })
    local c = make_comment({ id = "c1", reactions = { existing } })
    local d = make_discussion({ id = "d1", comments = { c } })
    local review = make_review(make_pr())
    local p = mock_provider.new({ discussions = { d } })
    p:react(review, "c1", "heart")
    local reactions = p:fetch_discussions(review)[1].comments[1].reactions
    -- count goes to 0; entry may be removed or count set to 0
    local found = false
    for _, r in ipairs(reactions) do
      if r.type == "heart" then
        found = true
        assert.equals(0, r.count)
        assert.is_false(r.viewer_reacted)
      end
    end
    if not found then
      -- acceptable: entry removed when count reaches 0
      assert.equals(0, #reactions)
    end
  end)

  it("errors when comment_id is not found", function()
    local review = make_review(make_pr())
    local p = mock_provider.new({ discussions = { make_discussion() } })
    assert.has_error(function()
      p:react(review, "no-such-comment", "+1")
    end)
  end)

  it("records the call", function()
    local c = make_comment({ id = "c1" })
    local d = make_discussion({ id = "d1", comments = { c } })
    local review = make_review(make_pr())
    local p = mock_provider.new({ discussions = { d } })
    p:react(review, "c1", "laugh")
    assert.equals(1, #p.calls.react)
    assert.equals("c1", p.calls.react[1].comment_id)
    assert.equals("laugh", p.calls.react[1].reaction)
  end)

  it("errors when configured to do so", function()
    local c = make_comment({ id = "c1" })
    local d = make_discussion({ id = "d1", comments = { c } })
    local review = make_review(make_pr())
    local p = mock_provider.new({ discussions = { d } })
    p:set_error("react", "api error")
    assert.has_error(function()
      p:react(review, "c1", "+1")
    end, "api error")
  end)
end)

-- ---------------------------------------------------------------------------
-- edit
-- ---------------------------------------------------------------------------

describe("parley.mock_provider edit", function()
  it("updates the comment body and returns the updated comment", function()
    local c = make_comment({ id = "c1" })
    local d = make_discussion({ id = "d1", comments = { c } })
    local review = make_review(make_pr())
    local p = mock_provider.new({ discussions = { d } })
    local new_body = model.new_body({ text = "edited text", format = "markdown" })
    local updated = p:edit(review, "c1", new_body)
    assert.equals("c1", updated.id)
    assert.equals("edited text", updated.body.text)
    -- verify state is mutated
    local stored = p:fetch_discussions(review)[1].comments[1]
    assert.equals("edited text", stored.body.text)
  end)

  it("errors when comment_id is not found", function()
    local review = make_review(make_pr())
    local p = mock_provider.new({ discussions = { make_discussion() } })
    local new_body = model.new_body({ text = "x", format = "markdown" })
    assert.has_error(function()
      p:edit(review, "no-such", new_body)
    end)
  end)

  it("records the call", function()
    local c = make_comment({ id = "c1" })
    local d = make_discussion({ id = "d1", comments = { c } })
    local review = make_review(make_pr())
    local p = mock_provider.new({ discussions = { d } })
    local new_body = model.new_body({ text = "e", format = "markdown" })
    p:edit(review, "c1", new_body)
    assert.equals(1, #p.calls.edit)
    assert.equals("c1", p.calls.edit[1].comment_id)
  end)

  it("errors when configured to do so", function()
    local c = make_comment({ id = "c1" })
    local d = make_discussion({ id = "d1", comments = { c } })
    local review = make_review(make_pr())
    local p = mock_provider.new({ discussions = { d } })
    p:set_error("edit", "not yours")
    local new_body = model.new_body({ text = "e", format = "markdown" })
    assert.has_error(function()
      p:edit(review, "c1", new_body)
    end, "not yours")
  end)
end)

-- ---------------------------------------------------------------------------
-- delete
-- ---------------------------------------------------------------------------

describe("parley.mock_provider delete", function()
  it("removes the comment from its discussion", function()
    local c1 = make_comment({ id = "c1" })
    local c2 = make_comment({ id = "c2" })
    local d = make_discussion({ id = "d1", comments = { c1, c2 } })
    local review = make_review(make_pr())
    local p = mock_provider.new({ discussions = { d } })
    p:delete(review, "c1")
    local stored = p:fetch_discussions(review)[1].comments
    assert.equals(1, #stored)
    assert.equals("c2", stored[1].id)
  end)

  it("errors when comment_id is not found", function()
    local review = make_review(make_pr())
    local p = mock_provider.new({ discussions = { make_discussion() } })
    assert.has_error(function()
      p:delete(review, "ghost")
    end)
  end)

  it("records the call", function()
    local c = make_comment({ id = "c1" })
    local d = make_discussion({ id = "d1", comments = { c } })
    local review = make_review(make_pr())
    local p = mock_provider.new({ discussions = { d } })
    p:delete(review, "c1")
    assert.equals(1, #p.calls.delete)
    assert.equals("c1", p.calls.delete[1].comment_id)
  end)

  it("errors when configured to do so", function()
    local c = make_comment({ id = "c1" })
    local d = make_discussion({ id = "d1", comments = { c } })
    local review = make_review(make_pr())
    local p = mock_provider.new({ discussions = { d } })
    p:set_error("delete", "gone")
    assert.has_error(function()
      p:delete(review, "c1")
    end, "gone")
  end)
end)

-- ---------------------------------------------------------------------------
-- submit_review
-- ---------------------------------------------------------------------------

describe("parley.mock_provider submit_review", function()
  it("updates the PR review_status for approve event", function()
    local pr = make_pr()
    local review = make_review(pr)
    local p = mock_provider.new({ pr = pr })
    local body = model.new_body({ text = "LGTM", format = "markdown" })
    p:submit_review(review, "approve", body)
    assert.equals("approved", p.state.pr.review_status)
  end)

  it("updates the PR review_status for request_changes event", function()
    local pr = make_pr()
    local review = make_review(pr)
    local p = mock_provider.new({ pr = pr })
    local body = model.new_body({ text = "please fix", format = "markdown" })
    p:submit_review(review, "request_changes", body)
    assert.equals("changes_requested", p.state.pr.review_status)
  end)

  it("sets review_status to commented for comment event", function()
    local pr = make_pr()
    local review = make_review(pr)
    local p = mock_provider.new({ pr = pr })
    local body = model.new_body({ text = "note", format = "markdown" })
    p:submit_review(review, "comment", body)
    assert.equals("commented", p.state.pr.review_status)
  end)

  it("errors on unknown event", function()
    local pr = make_pr()
    local review = make_review(pr)
    local p = mock_provider.new({ pr = pr })
    local body = model.new_body({ text = "x", format = "markdown" })
    assert.has_error(function()
      p:submit_review(review, "superapprove", body)
    end)
  end)

  it("records the call", function()
    local pr = make_pr()
    local review = make_review(pr)
    local p = mock_provider.new({ pr = pr })
    local body = model.new_body({ text = "ok", format = "markdown" })
    p:submit_review(review, "approve", body)
    assert.equals(1, #p.calls.submit_review)
    local c = p.calls.submit_review[1]
    assert.equals("approve", c.event)
    assert.equals("ok", c.body.text)
  end)

  it("errors when configured to do so", function()
    local pr = make_pr()
    local review = make_review(pr)
    local p = mock_provider.new({ pr = pr })
    p:set_error("submit_review", "review window closed")
    local body = model.new_body({ text = "x", format = "markdown" })
    assert.has_error(function()
      p:submit_review(review, "approve", body)
    end, "review window closed")
  end)
end)
