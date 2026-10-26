local fixtures = require("tests.parley.providers.github.fixtures")
local async_tests = require("plenary.async.tests")
local provider_mod = require("parley.provider")
local gh = fixtures.gh
local PR_JSON = fixtures.PR_JSON
local make_runner = fixtures.make_runner
local ok = fixtures.ok
local fail = fixtures.fail
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
  async_tests.it("retries transient CLI reads with backoff", function()
    local calls, sleeps = 0, {}
    local runner = make_runner(function()
      calls = calls + 1
      return calls == 1 and fail("i/o timeout") or ok(PR_JSON)
    end)
    local p = make_provider({
      _runner = runner.fn,
      _sleep = function(ms)
        sleeps[#sleeps + 1] = ms
      end,
    })
    assert.equals("42", p:detect_pr("/repo", "feature").pr.id)
    assert.same({ 250 }, sleeps)
    assert.equals(2, calls)
  end)

  async_tests.it("does not retry authorization failures", function()
    local calls = 0
    local p = make_provider({
      _runner = function()
        calls = calls + 1
        return fail("HTTP 401: Bad credentials")
      end,
    })
    assert.has_error(function()
      p:detect_pr("/repo", "feature")
    end)
    assert.equals(1, calls)
  end)

  async_tests.it("passes the configured timeout to gh", function()
    local p = make_provider({
      _system = function(_, opts, cb)
        assert.equals(5000, opts.timeout)
        cb(ok(PR_JSON))
      end,
    })
    assert.equals("42", p:detect_pr("/repo", "feature").pr.id)
  end)

  async_tests.it("maps CLI metadata and preserves write context", function()
    local p = make_provider(function()
      return ok(PR_JSON)
    end)
    local review = p:detect_pr("/repo", "feature")
    assert.equals("Add feature", review.pr.title)
    assert.equals("open", review.pr.state)
    assert.equals("main", review.pr.base_branch)
    assert.equals("feature", review.pr.head_branch)
    assert.equals("alice", review.pr.author)
    assert.equals("https://github.com/owner/repo/pull/42", review.pr.url)
    assert.equals("abc123def456", review.head_sha)
    assert.same({ number = 42, head_sha = "abc123def456" }, review.write_context)
  end)

  async_tests.it("passes a branch as one argument without shell interpolation", function()
    local p = make_provider(function(cmd)
      assert.equals("feature/topic&value", cmd[4])
      return fail('no pull requests found for branch "feature/topic&value"')
    end)
    assert.is_nil(p:detect_pr("/repo", "feature/topic&value"))
  end)

  for _, value in ipairs({ "null", "{}", "[]", "invalid JSON" }) do
    async_tests.it("rejects malformed metadata: " .. value, function()
      local p = make_provider(function()
        return ok(value)
      end)
      assert.has_error(function()
        p:detect_pr("/repo", "feature")
      end)
    end)
  end
end)
