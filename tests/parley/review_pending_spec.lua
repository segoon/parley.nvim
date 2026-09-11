local model = require("parley.model")
local pending = require("parley.repositories.review_pending")

describe("review pending comment preservation", function()
  it("keeps pending replies across an overlapping remote refresh", function()
    local root = model.new_comment({
      id = "root",
      author = "bob",
      body = model.new_body({ text = "root", format = "markdown" }),
      created_at = "2026-09-11T11:00:00Z",
      updated_at = "2026-09-11T11:00:00Z",
    })
    local optimistic = model.new_comment({
      id = "pending",
      author = "you",
      body = model.new_body({ text = "reply", format = "markdown" }),
      created_at = "",
      updated_at = "",
      parent_comment_id = "root",
      pending = true,
    })
    local current = {
      all_discussions = {
        model.new_discussion({ id = "root", file = "f", line = 1, comments = { root, optimistic } }),
      },
    }
    local incoming = {
      all_discussions = {
        model.new_discussion({ id = "root", file = "f", line = 1, comments = { root } }),
      },
    }

    pending.preserve(current, incoming, function()
      return { unresolved_count = 1 }
    end)

    assert.equals(2, #incoming.all_discussions[1].comments)
    assert.is_true(incoming.all_discussions[1].comments[2].pending)
    assert.same({ unresolved_count = 1 }, incoming.summary)
  end)
end)
