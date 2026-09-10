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
