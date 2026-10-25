local fixtures = require("tests.parley.providers.github.fixtures")
local async_tests = require("plenary.async.tests")
local provider_mod = require("parley.provider")
local gh = fixtures.gh
local PR_LIST_JSON = fixtures.PR_LIST_JSON
local PR_LIST_EMPTY_JSON = fixtures.PR_LIST_EMPTY_JSON
local REVIEWS_APPROVED_JSON = fixtures.REVIEWS_APPROVED_JSON
local REVIEWS_CHANGES_JSON = fixtures.REVIEWS_CHANGES_JSON
local REVIEWS_EMPTY_JSON = fixtures.REVIEWS_EMPTY_JSON
local make_runner = fixtures.make_runner
local ok = fixtures.ok
local fail = fixtures.fail
local make_route_runner = fixtures.make_route_runner
local make_auth = fixtures.make_auth
local make_auth_err = fixtures.make_auth_err
local make_provider = fixtures.make_provider

describe("parley.providers.github.provider — new / validate", function()
  it("returns a table that passes provider.validate()", function()
    local p = gh.new({ repository = "o/r" })
    assert.is_true(provider_mod.validate(p))
  end)

  it("errors when repository is missing", function()
    assert.has_error(function()
      gh.new({})
    end)
  end)

  it("errors when repository is malformed", function()
    assert.has_error(function()
      gh.new({ repository = "not-valid" })
    end)
  end)
end)

async_tests.describe("parley.providers.github.provider — auth", function()
  async_tests.it("returns token from the auth module", function()
    local p = gh.new({ repository = "o/r", _auth = make_auth("ghp_ABC") })
    assert.equals("ghp_ABC", p:auth())
  end)

  async_tests.it("propagates error when auth module returns nil", function()
    local p = gh.new({ repository = "o/r", _auth = make_auth_err("no token") })
    assert.has_error(function()
      p:auth()
    end)
  end)
end)

async_tests.describe("parley.providers.github.provider — detect_pr", function()
  async_tests.it("retries transient gh transport failures with backoff", function()
    local sleeps = {}
    local pull_calls = 0
    local runner = make_runner(function(cmd)
      for _, arg in ipairs(cmd) do
        if arg:find("/reviews", 1, true) then
          return ok(REVIEWS_EMPTY_JSON)
        end
      end
      pull_calls = pull_calls + 1
      if pull_calls == 1 then
        return fail('Post "https://api.github.com": dial tcp 140.82.121.5:443: i/o timeout')
      end
      return ok(PR_LIST_JSON)
    end)
    local p = make_provider({
      _runner = runner.fn,
      _sleep = function(timeout_ms)
        sleeps[#sleeps + 1] = timeout_ms
      end,
    })

    local review = p:detect_pr("/repo/root", "feature")

    assert.is_not_nil(review)
    assert.equals(250, sleeps[1])
    assert.equals(3, #runner._calls)
  end)

  async_tests.it("does not retry non-retryable gh failures", function()
    local sleeps = {}
    local runner = make_runner(function(_cmd)
      return fail("HTTP 422: Validation Failed")
    end)
    local p = make_provider({
      _runner = runner.fn,
      _sleep = function(timeout_ms)
        sleeps[#sleeps + 1] = timeout_ms
      end,
    })

    local success, err = pcall(function()
      p:detect_pr("/repo/root", "feature")
    end)
    assert.is_false(success)
    assert.is_not_nil(tostring(err):find("parley.github: gh command failed", 1, true))
    assert.equals(0, #sleeps)
    assert.equals(1, #runner._calls)
  end)

  async_tests.it("passes a 5 second timeout to gh by default", function()
    local timeouts = {}
    local p = make_provider({
      _system = function(_cmd, opts, callback)
        timeouts[#timeouts + 1] = opts.timeout
        callback({ code = 0, stdout = PR_LIST_EMPTY_JSON, stderr = "" })
        return { kill = function() end }
      end,
    })

    local review = p:detect_pr("/repo/root", "feature")

    assert.is_nil(review)
    assert.equals(5000, timeouts[1])
  end)

  async_tests.it("returns nil when the PR list is empty", function()
    local runner = make_route_runner({
      { pattern = "/pulls", response = ok(PR_LIST_EMPTY_JSON) },
    })
    local p = make_provider(runner.fn)
    local review = p:detect_pr("/repo/root", "feature")
    assert.is_nil(review)
  end)

  async_tests.it("maps PR fields to parley.PR correctly", function()
    local runner = make_route_runner({
      { pattern = "/reviews", response = ok(REVIEWS_APPROVED_JSON) },
      { pattern = "/pulls", response = ok(PR_LIST_JSON) },
    })
    local p = make_provider(runner.fn)
    local review = p:detect_pr("/repo/root", "feature")

    assert.is_not_nil(review)
    assert.equals("42", review.pr.id)
    assert.equals("Add feature", review.pr.title)
    assert.equals("open", review.pr.state)
    assert.equals("main", review.pr.base_branch)
    assert.equals("feature", review.pr.head_branch)
    assert.equals("alice", review.pr.author)
    assert.equals("https://github.com/owner/repo/pull/42", review.pr.url)
  end)

  async_tests.it("sets review_status=approved when reviews show APPROVED", function()
    local runner = make_route_runner({
      { pattern = "/reviews", response = ok(REVIEWS_APPROVED_JSON) },
      { pattern = "/pulls", response = ok(PR_LIST_JSON) },
    })
    local p = make_provider(runner.fn)
    local review = p:detect_pr("/repo/root", "feature")
    assert.equals("approved", review.pr.review_status)
  end)

  async_tests.it("sets review_status=changes_requested when reviews show CHANGES_REQUESTED", function()
    local runner = make_route_runner({
      { pattern = "/reviews", response = ok(REVIEWS_CHANGES_JSON) },
      { pattern = "/pulls", response = ok(PR_LIST_JSON) },
    })
    local p = make_provider(runner.fn)
    local review = p:detect_pr("/repo/root", "feature")
    assert.equals("changes_requested", review.pr.review_status)
  end)

  async_tests.it("sets review_status=pending when no reviews exist", function()
    local runner = make_route_runner({
      { pattern = "/reviews", response = ok(REVIEWS_EMPTY_JSON) },
      { pattern = "/pulls", response = ok(PR_LIST_JSON) },
    })
    local p = make_provider(runner.fn)
    local review = p:detect_pr("/repo/root", "feature")
    assert.equals("pending", review.pr.review_status)
  end)

  async_tests.it("returns explicit write context for later use", function()
    local runner = make_route_runner({
      { pattern = "/reviews", response = ok(REVIEWS_EMPTY_JSON) },
      { pattern = "/pulls", response = ok(PR_LIST_JSON) },
    })
    local p = make_provider(runner.fn)
    local review = p:detect_pr("/repo/root", "feature")
    assert.equals("abc123def456", review.head_sha)
    assert.same({ head_sha = "abc123def456", number = 42 }, review.write_context)
  end)

  async_tests.it("passes the branch in the query string", function()
    local runner = make_runner(function(cmd)
      -- Check the pulls URL contains the head filter
      local url_arg = nil
      for _, a in ipairs(cmd) do
        if a:find("/pulls", 1, true) then
          url_arg = a
          break
        end
      end
      assert.is_not_nil(url_arg)
      assert.is_not_nil(url_arg:find("owner:my%-branch", 1, false))
      return ok(PR_LIST_EMPTY_JSON)
    end)
    local p = make_provider(runner.fn)
    p:detect_pr("/repo/root", "my-branch")
  end)
end)

async_tests.describe("parley.providers.github.provider — detect_pr write context", function()
  async_tests.it("returns write context after detect_pr", function()
    local runner = make_route_runner({
      { pattern = "/reviews", response = ok(REVIEWS_EMPTY_JSON) },
      { pattern = "/pulls", response = ok(PR_LIST_JSON) },
    })
    local p = make_provider(runner.fn)
    local review = p:detect_pr("/repo", "feature")

    assert.same({ number = 42, head_sha = "abc123def456" }, review.write_context)
  end)
end)
