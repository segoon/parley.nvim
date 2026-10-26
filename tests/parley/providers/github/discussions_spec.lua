local fixtures = require("tests.parley.providers.github.fixtures")
local async_tests = require("plenary.async.tests")
local COMMENTS_JSON = fixtures.COMMENTS_JSON
local COMMENTS_NULL_LINE_JSON = fixtures.COMMENTS_NULL_LINE_JSON
local USER_JSON = fixtures.USER_JSON
local REVIEW_THREADS_RESOLVED_JSON = fixtures.REVIEW_THREADS_RESOLVED_JSON
local REVIEW_THREADS_UNRESOLVED_JSON = fixtures.REVIEW_THREADS_UNRESOLVED_JSON
local make_runner = fixtures.make_runner
local ok = fixtures.ok
local fail = fixtures.fail
local make_route_runner = fixtures.make_route_runner
local make_provider = fixtures.make_provider
local make_review = fixtures.make_review

async_tests.describe("parley.providers.github.provider — fetch_discussions", function()
  async_tests.it("returns one Discussion per root comment", function()
    local runner = make_route_runner({
      { pattern = "/comments", response = ok(COMMENTS_JSON) },
    })
    local p = make_provider(runner.fn)
    local discussions = p:fetch_discussions(make_review())
    assert.equals(1, #discussions)
  end)

  async_tests.it("maps the root comment fields correctly", function()
    local runner = make_route_runner({
      { pattern = "/comments", response = ok(COMMENTS_JSON) },
    })
    local p = make_provider(runner.fn)
    local disc = p:fetch_discussions(make_review())[1]

    assert.equals("1001", disc.id)
    assert.equals("src/foo.lua", disc.file)
    assert.equals(10, disc.line)
    assert.is_false(disc.resolved) -- no graphql route configured → degrades to false
  end)

  async_tests.it("overlays resolved=true from the GraphQL reviewThreads query", function()
    local runner = make_route_runner({
      { pattern = "/comments", response = ok(COMMENTS_JSON) },
      { pattern = "graphql", response = ok(REVIEW_THREADS_RESOLVED_JSON) },
    })
    local p = make_provider(runner.fn)
    local disc = p:fetch_discussions(make_review())[1]
    assert.is_true(disc.resolved)
  end)

  async_tests.it("overlays resolved=false from the GraphQL reviewThreads query", function()
    local runner = make_route_runner({
      { pattern = "/comments", response = ok(COMMENTS_JSON) },
      { pattern = "graphql", response = ok(REVIEW_THREADS_UNRESOLVED_JSON) },
    })
    local p = make_provider(runner.fn)
    local disc = p:fetch_discussions(make_review())[1]
    assert.is_false(disc.resolved)
  end)

  async_tests.it("degrades to resolved=false when the GraphQL request fails", function()
    local runner = make_route_runner({
      { pattern = "/comments", response = ok(COMMENTS_JSON) },
      { pattern = "graphql", response = fail("boom") },
    })
    local p = make_provider(runner.fn)
    local discussions = p:fetch_discussions(make_review())
    assert.equals(1, #discussions)
    assert.is_false(discussions[1].resolved)
  end)

  async_tests.it("attaches two comments (root + reply) to the discussion", function()
    local runner = make_route_runner({
      { pattern = "/comments", response = ok(COMMENTS_JSON) },
    })
    local p = make_provider(runner.fn)
    local disc = p:fetch_discussions(make_review())[1]
    assert.equals(2, #disc.comments)
  end)

  async_tests.it("root comment has no parent_comment_id", function()
    local runner = make_route_runner({
      { pattern = "/comments", response = ok(COMMENTS_JSON) },
    })
    local p = make_provider(runner.fn)
    local root = p:fetch_discussions(make_review())[1].comments[1]
    assert.is_nil(root.parent_comment_id)
  end)

  async_tests.it("reply has parent_comment_id = root comment id", function()
    local runner = make_route_runner({
      { pattern = "/comments", response = ok(COMMENTS_JSON) },
    })
    local p = make_provider(runner.fn)
    local reply = p:fetch_discussions(make_review())[1].comments[2]
    assert.equals("1001", reply.parent_comment_id)
  end)

  async_tests.it("maps author and body fields on root comment", function()
    local runner = make_route_runner({
      { pattern = "/comments", response = ok(COMMENTS_JSON) },
    })
    local p = make_provider(runner.fn)
    local root = p:fetch_discussions(make_review())[1].comments[1]
    assert.equals("alice", root.author)
    assert.equals("First comment", root.body.text)
    assert.equals("markdown", root.body.format)
  end)

  async_tests.it("maps reactions: count and type from REST reactions object", function()
    local runner = make_route_runner({
      { pattern = "/comments", response = ok(COMMENTS_JSON) },
    })
    local p = make_provider(runner.fn)
    local root = p:fetch_discussions(make_review())[1].comments[1]
    -- root comment has total_count=1 and +1=1
    assert.equals(1, #root.reactions)
    assert.equals("+1", root.reactions[1].type)
    assert.equals(1, root.reactions[1].count)
  end)

  async_tests.it("falls back to original_line when line is null", function()
    local runner = make_route_runner({
      { pattern = "/comments", response = ok(COMMENTS_NULL_LINE_JSON) },
    })
    local p = make_provider(runner.fn)
    local disc = p:fetch_discussions(make_review())[1]
    assert.equals(5, disc.line)
  end)

  async_tests.it("produces two separate discussions for two root comments", function()
    local two_roots = vim.json.encode({
      {
        id = 100,
        user = { login = "a" },
        body = "Root A",
        created_at = "2024-01-01T10:00:00Z",
        updated_at = "2024-01-01T10:00:00Z",
        path = "a.lua",
        line = 1,
        original_line = 1,
        start_line = vim.NIL,
        in_reply_to_id = vim.NIL,
        reactions = {
          total_count = 0,
          ["+1"] = 0,
          ["-1"] = 0,
          laugh = 0,
          hooray = 0,
          confused = 0,
          heart = 0,
          rocket = 0,
          eyes = 0,
        },
      },
      {
        id = 200,
        user = { login = "b" },
        body = "Root B",
        created_at = "2024-01-01T10:00:01Z",
        updated_at = "2024-01-01T10:00:01Z",
        path = "b.lua",
        line = 2,
        original_line = 2,
        start_line = vim.NIL,
        in_reply_to_id = vim.NIL,
        reactions = {
          total_count = 0,
          ["+1"] = 0,
          ["-1"] = 0,
          laugh = 0,
          hooray = 0,
          confused = 0,
          heart = 0,
          rocket = 0,
          eyes = 0,
        },
      },
    })
    local runner = make_route_runner({
      { pattern = "/comments", response = ok(two_roots) },
    })
    local p = make_provider(runner.fn)
    local discussions = p:fetch_discussions(make_review())
    assert.equals(2, #discussions)
  end)
end)

async_tests.describe("parley.providers.github.provider — fetch_discussions is_own", function()
  async_tests.it("sets is_own=true for comments authored by the viewer (authenticated API)", function()
    local runner = make_route_runner({
      { pattern = "/user", response = ok(USER_JSON) },
      { pattern = "/comments", response = ok(COMMENTS_JSON) },
    })
    local p = make_provider(runner.fn)
    local comments = p:fetch_discussions(make_review())[1].comments
    assert.is_true(comments[1].is_own) -- alice's root comment
    assert.is_false(comments[2].is_own) -- bob's reply
  end)

  async_tests.it("sets is_own=true for comments authored by the viewer (another authenticated viewer)", function()
    local runner = make_route_runner({
      { pattern = "/user", response = ok('{"login":"bob"}') },
      { pattern = "/comments", response = ok(COMMENTS_JSON) },
    })
    local p = make_provider(runner.fn)
    local comments = p:fetch_discussions(make_review())[1].comments
    assert.is_false(comments[1].is_own) -- alice's root comment
    assert.is_true(comments[2].is_own) -- bob's reply
  end)

  async_tests.it("sets is_own=false for all comments when viewer is unknown", function()
    local runner = make_route_runner({
      { pattern = "/comments", response = ok(COMMENTS_JSON) },
      -- no /user route → gh_run raises → pcall catches → _viewer_login stays nil
    })
    local p = make_provider(runner.fn)
    local comments = p:fetch_discussions(make_review())[1].comments
    assert.is_false(comments[1].is_own)
    assert.is_false(comments[2].is_own)
  end)

  async_tests.it("caches viewer login: second fetch_discussions does not call runner for identity", function()
    local identity_call_count = 0
    local runner = make_runner(function(cmd)
      if vim.tbl_contains(cmd, "/user") then
        identity_call_count = identity_call_count + 1
        return ok(USER_JSON)
      end
      -- gh api --paginate /comments
      return ok(COMMENTS_JSON)
    end)
    local p = make_provider(runner.fn)
    p:fetch_discussions(make_review())
    p:fetch_discussions(make_review())
    assert.equals(1, identity_call_count)
  end)
end)
