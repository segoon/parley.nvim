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
