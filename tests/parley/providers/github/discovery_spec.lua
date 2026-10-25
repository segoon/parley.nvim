local fixtures = require("tests.parley.providers.github.fixtures")
local async_tests = require("plenary.async.tests")
local model = fixtures.model
local gh = fixtures.gh
local make_runner = fixtures.make_runner
local ok = fixtures.ok
local make_auth = fixtures.make_auth
local make_provider = fixtures.make_provider
local make_review = fixtures.make_review

async_tests.describe("parley.providers.github.provider — submit_review", function()
  local function review_runner()
    return make_runner(function(_cmd)
      return ok(vim.json.encode({ id = 77, state = "APPROVED" }))
    end)
  end

  async_tests.it("maps 'approve' to APPROVE event", function()
    local runner = review_runner()
    local p = make_provider(runner.fn)
    local body = model.new_body({ text = "lgtm", format = "markdown" })
    p:submit_review(make_review("abc123"), "approve", body)

    local cmd = runner._calls[1]
    local has_event = false
    for i, v in ipairs(cmd) do
      if v == "-f" and cmd[i + 1] and cmd[i + 1] == "event=APPROVE" then
        has_event = true
        break
      end
    end
    assert.is_true(has_event)
  end)

  async_tests.it("maps 'request_changes' to REQUEST_CHANGES event", function()
    local runner = review_runner()
    local p = make_provider(runner.fn)
    local body = model.new_body({ text = "needs work", format = "markdown" })
    p:submit_review(make_review("abc123"), "request_changes", body)

    local cmd = runner._calls[1]
    local has_event = false
    for i, v in ipairs(cmd) do
      if v == "-f" and cmd[i + 1] and cmd[i + 1] == "event=REQUEST_CHANGES" then
        has_event = true
        break
      end
    end
    assert.is_true(has_event)
  end)

  async_tests.it("maps 'comment' to COMMENT event", function()
    local runner = review_runner()
    local p = make_provider(runner.fn)
    local body = model.new_body({ text = "fyi", format = "markdown" })
    p:submit_review(make_review("abc123"), "comment", body)

    local cmd = runner._calls[1]
    local has_event = false
    for i, v in ipairs(cmd) do
      if v == "-f" and cmd[i + 1] and cmd[i + 1] == "event=COMMENT" then
        has_event = true
        break
      end
    end
    assert.is_true(has_event)
  end)

  async_tests.it("errors on unknown event", function()
    local runner = review_runner()
    local p = make_provider(runner.fn)
    local body = model.new_body({ text = "x", format = "markdown" })
    assert.has_error(function()
      p:submit_review(make_review("abc123"), "invalid_event", body)
    end)
  end)
end)

describe("parley.providers.github.provider — progress_label", function()
  it("returns 'github.com' for the default host", function()
    local p = make_provider({})
    assert.equals("github.com", p:progress_label())
  end)

  it("returns the configured host for a GitHub Enterprise instance", function()
    local p = gh.new({ host = "github.mycompany.com", repository = "owner/repo", _auth = make_auth("token") })
    assert.equals("github.mycompany.com", p:progress_label())
  end)
end)

describe("parley.providers.github.provider — _parse_remote_url", function()
  it("parses SSH form (github.com)", function()
    assert.same(
      { host = "github.com", owner = "owner", repo = "repo" },
      gh._parse_remote_url("git@github.com:owner/repo.git")
    )
  end)

  it("parses SSH form without trailing .git", function()
    assert.same(
      { host = "github.com", owner = "owner", repo = "repo" },
      gh._parse_remote_url("git@github.com:owner/repo")
    )
  end)

  it("parses HTTPS form (github.com)", function()
    assert.same(
      { host = "github.com", owner = "owner", repo = "repo" },
      gh._parse_remote_url("https://github.com/owner/repo.git")
    )
  end)

  it("parses HTTPS form without trailing .git", function()
    assert.same(
      { host = "github.com", owner = "owner", repo = "repo" },
      gh._parse_remote_url("https://github.com/owner/repo")
    )
  end)

  it("parses HTTPS form with embedded user@", function()
    assert.same(
      { host = "github.com", owner = "owner", repo = "repo" },
      gh._parse_remote_url("https://user@github.com/owner/repo.git")
    )
  end)

  it("parses SSH form for an Enterprise host", function()
    assert.same(
      { host = "github.corp.example.com", owner = "team", repo = "svc" },
      gh._parse_remote_url("git@github.corp.example.com:team/svc.git")
    )
  end)

  it("returns nil for nil input", function()
    assert.is_nil(gh._parse_remote_url(nil))
  end)

  it("returns nil for empty string", function()
    assert.is_nil(gh._parse_remote_url(""))
  end)

  it("returns nil for unrecognized scheme", function()
    assert.is_nil(gh._parse_remote_url("file:///tmp/repo"))
  end)

  it("returns nil for malformed input", function()
    assert.is_nil(gh._parse_remote_url("not a url"))
  end)
end)

describe("parley.providers.github.provider — detect", function()
  it("returns repository/host for an SSH github.com URL", function()
    local opts = gh.detect({
      vcs = "git",
      root = "/some/repo",
      branch = "main",
      remote_url = "git@github.com:owner/repo.git",
    })
    assert.same({ host = "github.com", repository = "owner/repo" }, opts)
  end)

  it("returns repository/host for an HTTPS github.com URL", function()
    local opts = gh.detect({
      vcs = "git",
      root = "/some/repo",
      branch = "main",
      remote_url = "https://github.com/owner/repo",
    })
    assert.same({ host = "github.com", repository = "owner/repo" }, opts)
  end)

  it("returns nil for a non-GitHub host (gitlab.com)", function()
    assert.is_nil(gh.detect({
      vcs = "git",
      root = "/some/repo",
      branch = "main",
      remote_url = "git@gitlab.com:owner/repo.git",
    }))
  end)

  it("returns nil when remote_url is missing", function()
    assert.is_nil(gh.detect({ vcs = "git", root = "/some/repo", branch = "main" }))
  end)

  it("returns nil when vcs_info is not a table", function()
    assert.is_nil(gh.detect(nil))
  end)

  it("returns nil for an Enterprise host (kept conservative for now)", function()
    -- github.corp.example.com is parsed but the host check rejects non-github.com.
    assert.is_nil(gh.detect({
      vcs = "git",
      root = "/r",
      branch = "main",
      remote_url = "git@github.corp.example.com:team/svc.git",
    }))
  end)
end)
