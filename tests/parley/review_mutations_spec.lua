local contexts = require("parley.repositories.context")
local model = require("parley.model")
local reviews = require("parley.repositories.review")

describe("review optimistic comment mutations", function()
  local saved

  before_each(function()
    saved = {
      reviews = reviews._reviews,
      views = reviews._views,
      bufnr_key = reviews._bufnr_key,
      key_bufnrs = reviews._key_bufnrs,
      subscribers = reviews._subscribers,
      contexts = contexts._entries,
    }
    reviews._reviews, reviews._views = {}, {}
    reviews._bufnr_key, reviews._key_bufnrs = {}, {}
    reviews._subscribers, contexts._entries = {}, {}
    contexts._entries[1] = {
      kind = "regular",
      path = "/repo/src/foo.lua",
      rel_path = "src/foo.lua",
      vcs_info = { vcs = "git", root = "/repo", branch = "feature" },
    }
    reviews._seed(1, {
      review = { pr = { id = "42" }, head_sha = "head" },
      head_sha = "head",
      all_discussions = {},
      discussions = {},
      mappings = {},
    }, "optimistic/review")
  end)

  after_each(function()
    reviews._reviews, reviews._views = saved.reviews, saved.views
    reviews._bufnr_key, reviews._key_bufnrs = saved.bufnr_key, saved.key_bufnrs
    reviews._subscribers, contexts._entries = saved.subscribers, saved.contexts
  end)

  it("stages and confirms a new discussion without waiting for refresh", function()
    local token = assert(reviews.stage_comment(1, {
      kind = "new",
      file = "src/foo.lua",
      anchor = { start_line = 4, end_line = 6 },
      body = model.new_body({ text = "new thread", format = "markdown" }),
    }))

    local staged = reviews.get(1)
    assert.equals(1, #staged.all_discussions)
    assert.is_true(staged.all_discussions[1].comments[1].pending)
    assert.equals("new thread", staged.all_discussions[1].comments[1].body.text)
    assert.same(
      { local_line = 4, local_end_line = 6, confidence = 1.0, stale = false },
      staged.mappings[token.discussion_id]
    )

    local server_comment = model.new_comment({
      id = "9001",
      author = "alice",
      body = model.new_body({ text = "new thread", format = "markdown" }),
      created_at = "2026-09-11T12:00:00Z",
      updated_at = "2026-09-11T12:00:00Z",
      is_own = true,
    })
    assert.equals("9001", reviews.confirm_comment(token, server_comment))

    local confirmed = reviews.get(1)
    assert.equals("9001", confirmed.all_discussions[1].id)
    assert.equals("9001", confirmed.all_discussions[1].comments[1].id)
    assert.is_nil(confirmed.all_discussions[1].comments[1].pending)
    assert.same({ local_line = 4, local_end_line = 6, confidence = 1.0, stale = false }, confirmed.mappings["9001"])
    assert.is_nil(confirmed.mappings[token.discussion_id])
  end)

  it("rolls back a staged reply without changing the existing thread", function()
    local root = model.new_comment({
      id = "root",
      author = "bob",
      body = model.new_body({ text = "root", format = "markdown" }),
      created_at = "2026-09-11T11:00:00Z",
      updated_at = "2026-09-11T11:00:00Z",
    })
    local discussion = model.new_discussion({
      id = "root",
      file = "src/foo.lua",
      line = 8,
      comments = { root },
    })
    reviews._seed(1, {
      review = { pr = { id = "42" }, head_sha = "head" },
      head_sha = "head",
      all_discussions = { discussion },
      discussions = { discussion },
      mappings = { root = { local_line = 8, confidence = 1.0, stale = false } },
    }, "optimistic/review")

    local token = assert(reviews.stage_comment(1, {
      kind = "reply",
      discussion_id = "root",
      parent_comment_id = "root",
      body = model.new_body({ text = "reply", format = "markdown" }),
    }))
    assert.equals(2, #reviews.get(1).all_discussions[1].comments)
    assert.is_true(reviews.rollback_comment(token))

    local rolled_back = reviews.get(1)
    assert.equals(1, #rolled_back.all_discussions[1].comments)
    assert.equals("root", rolled_back.all_discussions[1].comments[1].id)
  end)

  it("deduplicates a reply already observed by a racing refresh", function()
    local root = model.new_comment({
      id = "root",
      author = "bob",
      body = model.new_body({ text = "root", format = "markdown" }),
      created_at = "2026-09-11T11:00:00Z",
      updated_at = "2026-09-11T11:00:00Z",
    })
    local discussion = model.new_discussion({
      id = "root",
      file = "src/foo.lua",
      line = 8,
      comments = { root },
    })
    reviews._seed(1, {
      review = { pr = { id = "42" }, head_sha = "head" },
      head_sha = "head",
      all_discussions = { discussion },
      discussions = { discussion },
      mappings = { root = { local_line = 8, confidence = 1.0, stale = false } },
    }, "optimistic/review")
    local token = assert(reviews.stage_comment(1, {
      kind = "reply",
      discussion_id = "root",
      parent_comment_id = "root",
      body = model.new_body({ text = "reply", format = "markdown" }),
    }))
    local server_comment = model.new_comment({
      id = "reply-id",
      author = "alice",
      body = model.new_body({ text = "reply", format = "markdown" }),
      created_at = "2026-09-11T12:00:00Z",
      updated_at = "2026-09-11T12:00:00Z",
      parent_comment_id = "root",
    })
    local key = reviews.key_for_bufnr(1)
    reviews._reviews[key].all_discussions[1].comments[#reviews._reviews[key].all_discussions[1].comments + 1] =
      server_comment

    assert.equals("root", reviews.confirm_comment(token, server_comment))
    local comments = reviews.get(1).all_discussions[1].comments
    assert.equals(2, #comments)
    assert.equals("reply-id", comments[2].id)
  end)
end)
