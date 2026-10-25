--- Tests for parley.providers.github.mapping — GraphQL review-thread mapping.
--- Run via: make test

local mapping = require("parley.providers.github.mapping")

describe("parley.providers.github.mapping — map_review_thread_nodes", function()
  it("keys the result by the first comment's databaseId as a string", function()
    local lookup = mapping.map_review_thread_nodes({
      {
        id = "RT_1",
        isResolved = true,
        comments = { nodes = { { databaseId = 1001 } } },
      },
    })
    assert.same({ node_id = "RT_1", resolved = true }, lookup["1001"])
  end)

  it("maps isResolved = false to resolved = false", function()
    local lookup = mapping.map_review_thread_nodes({
      {
        id = "RT_2",
        isResolved = false,
        comments = { nodes = { { databaseId = 2002 } } },
      },
    })
    assert.is_false(lookup["2002"].resolved)
  end)

  it("skips nodes with no comments", function()
    local lookup = mapping.map_review_thread_nodes({
      { id = "RT_3", isResolved = true, comments = { nodes = {} } },
    })
    assert.same({}, lookup)
  end)

  it("handles multiple nodes in one call", function()
    local lookup = mapping.map_review_thread_nodes({
      { id = "RT_1", isResolved = true, comments = { nodes = { { databaseId = 1001 } } } },
      { id = "RT_2", isResolved = false, comments = { nodes = { { databaseId = 2002 } } } },
    })
    assert.equals("RT_1", lookup["1001"].node_id)
    assert.equals("RT_2", lookup["2002"].node_id)
  end)

  it("returns an empty table for an empty/nil node list", function()
    assert.same({}, mapping.map_review_thread_nodes({}))
    assert.same({}, mapping.map_review_thread_nodes(nil))
  end)
end)

describe("parley.providers.github.mapping — comment URLs", function()
  it("maps each review comment canonical URL", function()
    local comment = mapping.map_rest_comment({
      id = 1002,
      body = "Reply",
      user = { login = "alice" },
      html_url = "https://github.com/owner/repo/pull/42#discussion_r1002",
    }, "alice")

    assert.equals("https://github.com/owner/repo/pull/42#discussion_r1002", comment.url)
  end)

  it("maps the root comment URL onto the discussion", function()
    local discussions = mapping.group_comments_into_discussions({
      {
        id = 1001,
        path = "src/foo.lua",
        line = 10,
        body = "Root",
        user = { login = "alice" },
        created_at = "2024-01-01T10:00:00Z",
        updated_at = "2024-01-01T10:00:00Z",
        html_url = "https://github.com/owner/repo/pull/42#discussion_r1001",
      },
    }, "alice")

    assert.equals("https://github.com/owner/repo/pull/42#discussion_r1001", discussions[1].url)
    assert.equals(discussions[1].comments[1].url, discussions[1].url)
  end)
end)

describe("GitHub discussion locations", function()
  --- @param fields table
  --- @return parley.Discussion
  local function map(fields)
    local raw =
      vim.tbl_extend("force", { id = 1, path = "a.lua", body = "Comment", user = { login = "alice" } }, fields)
    return mapping.group_comments_into_discussions({ raw }, "alice")[1]
  end

  it("keeps whole-file comments readable when all line fields are JSON null", function()
    local discussion = map({ subject_type = "file", line = vim.NIL, original_line = vim.NIL, start_line = vim.NIL })
    assert.equals("file", discussion.anchor.kind)
    assert.equals("a.lua", discussion.file)
    assert.is_nil(discussion.line)
    assert.equals("Comment", discussion.comments[1].body.text)
    assert.is_false(require("parley.discussion").projectable(discussion))
  end)

  it("keeps unlocated line comments readable without inventing a file anchor", function()
    local discussion = map({ subject_type = "line", line = vim.NIL, original_line = vim.NIL })
    assert.equals("unavailable", discussion.anchor.kind)
    assert.is_nil(discussion.line)
  end)

  it("preserves both ends of a current multiline range", function()
    local discussion = map({ start_line = 3, line = 8 })
    assert.equals(3, discussion.line)
    assert.equals(8, discussion.end_line)
  end)

  it("uses original range endpoints together for an outdated comment", function()
    local discussion = map({ start_line = vim.NIL, line = vim.NIL, original_start_line = 3, original_line = 8 })
    assert.equals(3, discussion.line)
    assert.equals(8, discussion.end_line)
  end)

  it("does not mix an original range start into a current single-line comment", function()
    local discussion = map({ start_line = vim.NIL, line = 8, original_start_line = 2, original_line = 4 })
    assert.equals(8, discussion.line)
    assert.is_nil(discussion.end_line)
  end)

  for _, fields in ipairs({ { line = 8, start_line = 10 }, { line = -1 }, { path = vim.NIL, line = 8 } }) do
    it("degrades malformed locations to unavailable", function()
      local discussion = map(fields)
      assert.equals("unavailable", discussion.anchor.kind)
      assert.is_false(require("parley.discussion").projectable(discussion))
    end)
  end
end)
