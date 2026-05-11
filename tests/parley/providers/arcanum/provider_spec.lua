--- Tests for parley.providers.arcanum.provider — Arcanum provider implementation.
--- Run via: make test

local async_tests = require("plenary.async.tests")
local provider_mod = require("parley.provider")
local model = require("parley.model")
local arcanum = require("parley.providers.arcanum.provider")
local transport = require("parley.providers.arcanum.transport")

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

--- Build a minimal Arcanum PR search result.
local function pr_search_result(pr_id, branch)
  return {
    pull_requests = {
      {
        id = pr_id,
        summary = "My PR",
        status = "open",
        url = "https://arcanum.yandex.net/review/" .. tostring(pr_id),
        author = { name = "alice" },
        vcs = {
          from_branch = branch,
          to_branch = "trunk",
          type = "arc",
        },
      },
    },
    has_next = false,
  }
end

--- Build a minimal active diff response.
local function active_diff(diff_id, gsid, head)
  return {
    id = diff_id,
    gsid = gsid,
    published = true,
    commit_ids = {
      head = head or "arc-head-sha",
      base = "arc-base-sha",
    },
  }
end

--- Build a minimal Arcanum comment object.
local function raw_comment(id, content, reply_to)
  return {
    id = id,
    user = { name = "alice", uid = "123" },
    content = content or "Hello",
    created_at = "2024-01-01T10:00:00Z",
    updated_at = "2024-01-01T10:00:00Z",
    reply_to_id = reply_to or vim.NIL,
    reactions = {},
    issue_status = "not_issue",
    anchor = {
      review_request = {
        id = 1,
        diff = {
          diff_set_xid = "xid-123",
          file = {
            path = "src/foo.lua",
            position = { line = 10, size = 1, side = "new" },
          },
        },
      },
    },
  }
end

-- ---------------------------------------------------------------------------
-- Provider factory
-- ---------------------------------------------------------------------------

--- Build a mock provider with an injectable http_run sequence.
--- responses: list of { method, path, response } tuples (in order).
--- @param responses table[]
--- @return parley.arcanum.Provider, table  provider, calls_log
local function make_provider(responses)
  local calls = {}
  local idx = 0

  local mock_http_run = function(_self, method, path, body)
    idx = idx + 1
    table.insert(calls, { method = method, path = path, body = body })
    local r = responses[idx]
    assert(r, string.format("mock http_run: unexpected call #%d (method=%s path=%s)", idx, method, path))
    if r.error then
      error(r.error, 0)
    end
    return r.response
  end

  local p = arcanum.new({
    branch = "users/alice/my-feature",
    login = "alice",
    _auth = {
      read_token = function()
        return "test-token", nil
      end,
      read_token_async = function()
        return "test-token", nil
      end,
    },
    _sleep = function(_ms) end,
    _defer = function(cb, _ms)
      cb()
      return nil
    end,
    _get_config = function()
      return {
        providers = {
          arcanum = {
            timeout_ms = 5000,
            retry_count = 0,
            retry_base_delay_ms = 250,
            retry_max_delay_ms = 2000,
          },
        },
      }
    end,
  })

  -- Override transport.http_run on the provider
  transport.http_run = mock_http_run

  return p, calls
end

-- Save/restore transport.http_run
local original_http_run

local function save_transport()
  original_http_run = transport.http_run
end

local function restore_transport()
  transport.http_run = original_http_run
end

-- ---------------------------------------------------------------------------
-- Suite: provider interface validation
-- ---------------------------------------------------------------------------

describe("parley.providers.arcanum.provider — interface", function()
  it("satisfies parley.Provider interface", function()
    local p = arcanum.new({
      _auth = {
        read_token = function()
          return "token", nil
        end,
        read_token_async = function()
          return "token", nil
        end,
      },
      _sleep = function(_ms) end,
      _defer = function(cb, _ms)
        cb()
        return nil
      end,
      _get_config = function()
        return nil
      end,
    })

    assert.is_true(provider_mod.validate(p))
  end)
end)

-- ---------------------------------------------------------------------------
-- Suite: detect
-- ---------------------------------------------------------------------------

describe("parley.providers.arcanum.provider — detect", function()
  it("returns opts for vcs='arc'", function()
    local vcs_info = { vcs = "arc", root = "/arc", branch = "users/alice/feat", remote_url = "arc://alice" }
    local opts = arcanum.detect(vcs_info)
    assert.is_not_nil(opts)
  end)

  it("returns nil for vcs='git'", function()
    local vcs_info = { vcs = "git", root = "/repo", branch = "main", remote_url = "https://github.com/org/repo" }
    local opts = arcanum.detect(vcs_info)
    assert.is_nil(opts)
  end)

  it("returns nil for non-table vcs_info", function()
    assert.is_nil(arcanum.detect(nil))
    assert.is_nil(arcanum.detect("string"))
  end)

  it("extracts remote branch id from vcs_info", function()
    local vcs_info = {
      vcs = "arc",
      root = "/arc",
      branch = "users/alice/my-feature",
      remote_url = "arc://alice",
    }
    local opts = arcanum.detect(vcs_info)
    assert.equals("users/alice/my-feature", opts.branch)
  end)

  it("extracts login from remote_url arc:// scheme", function()
    local vcs_info = {
      vcs = "arc",
      root = "/arc",
      branch = "users/bob/feat",
      remote_url = "arc://bob",
    }
    local opts = arcanum.detect(vcs_info)
    assert.equals("bob", opts.login)
  end)

  it("returns nil login when remote_url is nil", function()
    local vcs_info = { vcs = "arc", root = "/arc", branch = "trunk", remote_url = nil }
    local opts = arcanum.detect(vcs_info)
    assert.is_nil(opts.login)
  end)
end)

-- ---------------------------------------------------------------------------
-- Suite: auth
-- ---------------------------------------------------------------------------

describe("parley.providers.arcanum.provider — auth", function()
  it("returns token from auth module", function()
    local p = arcanum.new({
      _auth = {
        read_token = function()
          return "my-token", nil
        end,
        read_token_async = function()
          return "my-token", nil
        end,
      },
      _sleep = function() end,
      _defer = function(cb, _)
        cb()
        return nil
      end,
      _get_config = function()
        return nil
      end,
    })

    assert.equals("my-token", p:auth())
  end)

  it("raises error when no token available", function()
    local p = arcanum.new({
      _auth = {
        read_token = function()
          return nil, "no token"
        end,
        read_token_async = function()
          return nil, "no token"
        end,
      },
      _sleep = function() end,
      _defer = function(cb, _)
        cb()
        return nil
      end,
      _get_config = function()
        return nil
      end,
    })
    -- Clear the token that was set during new() (it got nil)
    p._token = nil

    assert.has_error(function()
      p:auth()
    end)
  end)
end)

-- ---------------------------------------------------------------------------
-- Suite: detect_pr
-- ---------------------------------------------------------------------------

async_tests.describe("parley.providers.arcanum.provider — detect_pr", function()
  async_tests.before_each(save_transport)
  async_tests.after_each(restore_transport)

  local function minimal_search_result(pr_id)
    return {
      pull_requests = {
        { id = pr_id },
      },
      has_next = false,
    }
  end

  async_tests.it("returns nil when no PRs found", function()
    local p, _ = make_provider({
      { response = { pull_requests = {}, has_next = false } }, -- search
    })

    local result = p:detect_pr("/arc", "users/alice/feature")

    assert.is_nil(result)
  end)

  async_tests.it("returns DetectedReview on success", function()
    local p, _ = make_provider({
      { response = minimal_search_result(42) }, -- search
      { response = pr_search_result(42, "users/alice/feature").pull_requests[1] }, -- full PR
      { response = active_diff(101, "ARC:DEADBEEF", "arc-sha") }, -- active-diff
    })

    local result = p:detect_pr("/arc", "users/alice/feature")

    assert.is_not_nil(result)
    assert.equals("42", result.pr.id)
    assert.equals("My PR", result.pr.title)
    assert.equals("arc-sha", result.head_sha)
  end)

  async_tests.it("write_context contains pr_id and diff metadata", function()
    local p, _ = make_provider({
      { response = minimal_search_result(42) },
      { response = pr_search_result(42, "users/alice/feature").pull_requests[1] },
      { response = active_diff(101, "ARC:DEADBEEF") },
    })

    local result = p:detect_pr("/arc", "users/alice/feature")

    assert.equals(42, result.write_context.pr_id)
    assert.equals(101, result.write_context.diff_id)
    assert.equals("ARC:DEADBEEF", result.write_context.diff_set_xid)
  end)

  async_tests.it("returns nil when branch does not match any PR", function()
    local p, _ = make_provider({
      { response = minimal_search_result(1) },
      {
        response = {
          id = 1,
          summary = "Other PR",
          status = "open",
          url = "",
          author = { name = "bob" },
          vcs = { from_branch = "users/bob/other", to_branch = "trunk", type = "arc" },
        },
      },
    })

    local result = p:detect_pr("/arc", "users/alice/feature")

    assert.is_nil(result)
  end)

  async_tests.it("proceeds without active diff when active-diff call fails", function()
    local p, _ = make_provider({
      { response = minimal_search_result(42) },
      { response = pr_search_result(42, "users/alice/feature").pull_requests[1] },
      { error = "diff not found" }, -- active-diff fails
    })

    -- Should not throw; diff_id will be nil
    local result = p:detect_pr("/arc", "users/alice/feature")

    assert.is_not_nil(result)
    assert.is_nil(result.write_context.diff_id)
  end)

  async_tests.it("posts search request to correct path", function()
    local p, calls = make_provider({
      { response = { pull_requests = {}, has_next = false } },
    })

    p:detect_pr("/arc", "users/alice/feature")

    assert.equals("POST", calls[1].method)
    assert.equals("/v1/pull-requests/cursor", calls[1].path)
  end)

  async_tests.it("searches using the provided remote branch id", function()
    local p, calls = make_provider({
      { response = { pull_requests = {}, has_next = false } },
    })

    p:detect_pr("/arc", "users/segoon/feature/chaotic-const")

    assert.same({
      limit = 1,
      filter = {
        user_branch_prefix = "users/segoon/feature/chaotic-const",
        state = { published = true },
      },
    }, calls[1].body)
  end)

  async_tests.it("fetches full PR details before matching by branch", function()
    local p, calls = make_provider({
      { response = minimal_search_result(13323715) },
      { response = pr_search_result(13323715, "users/segoon/feature/chaotic-const").pull_requests[1] },
      { response = active_diff(101, "ARC:DEADBEEF") },
    })

    local result = p:detect_pr("/arc", "users/segoon/feature/chaotic-const")

    assert.is_not_nil(result)
    assert.equals("GET", calls[2].method)
    assert.equals("/v1/pull-requests/13323715?fields=id,summary,status,url,author,vcs", calls[2].path)
  end)
end)

-- ---------------------------------------------------------------------------
-- Suite: fetch_discussions
-- ---------------------------------------------------------------------------

async_tests.describe("parley.providers.arcanum.provider — fetch_discussions", function()
  async_tests.before_each(save_transport)
  async_tests.after_each(restore_transport)

  async_tests.it("returns empty list when API returns nil", function()
    local p, _ = make_provider({ { response = nil } })

    local write_context = { pr_id = 42, diff_id = nil, diff_set_xid = nil, changelist = {} }
    local review = {
      pr = model.new_pr({
        id = "42",
        title = "test",
        state = "open",
        base_branch = "trunk",
        head_branch = "users/alice/feat",
        author = "alice",
        url = "",
        review_status = "pending",
      }),
      head_sha = "",
      write_context = write_context,
    }

    local result = p:fetch_discussions(review)

    assert.same({}, result)
  end)

  async_tests.it("returns discussions from API comments", function()
    local p, _ = make_provider({
      { response = { raw_comment(1, "Root comment") } },
    })

    local write_context = { pr_id = 42, diff_id = nil, diff_set_xid = nil, changelist = {} }
    local review = {
      pr = model.new_pr({
        id = "42",
        title = "test",
        state = "open",
        base_branch = "trunk",
        head_branch = "users/alice/feat",
        author = "alice",
        url = "",
        review_status = "pending",
      }),
      head_sha = "",
      write_context = write_context,
    }

    local result = p:fetch_discussions(review)

    assert.equals(1, #result)
    assert.equals("1", result[1].id)
  end)

  async_tests.it("calls correct endpoint path", function()
    local p, calls = make_provider({ { response = {} } })

    local write_context = { pr_id = 99, diff_id = nil, diff_set_xid = nil, changelist = {} }
    local review = {
      pr = model.new_pr({
        id = "99",
        title = "t",
        state = "open",
        base_branch = "trunk",
        head_branch = "b",
        author = "a",
        url = "",
        review_status = "pending",
      }),
      head_sha = "",
      write_context = write_context,
    }

    p:fetch_discussions(review)

    assert.equals("GET", calls[1].method)
    assert.equals("/v1/public/review-requests/99/comments", calls[1].path)
  end)
end)

-- ---------------------------------------------------------------------------
-- Suite: reply
-- ---------------------------------------------------------------------------

async_tests.describe("parley.providers.arcanum.provider — reply", function()
  async_tests.before_each(save_transport)
  async_tests.after_each(restore_transport)

  async_tests.it("calls replies endpoint on parent comment id", function()
    local p, calls = make_provider({
      { response = raw_comment(200, "My reply") },
    })

    local write_context = { pr_id = 42, diff_id = nil, diff_set_xid = nil, changelist = {} }
    local review = {
      pr = model.new_pr({
        id = "42",
        title = "t",
        state = "open",
        base_branch = "trunk",
        head_branch = "b",
        author = "a",
        url = "",
        review_status = "pending",
      }),
      head_sha = "",
      write_context = write_context,
    }
    local discussion = { id = "100", file = "f.lua", line = 1, resolved = false, comments = {} }
    local parent = model.new_comment({
      id = "100",
      author = "alice",
      body = model.new_body({ text = "root", format = "markdown" }),
      created_at = "",
      updated_at = "",
    })
    local body = model.new_body({ text = "Reply text", format = "markdown" })

    local result = p:reply(review, discussion, parent, body)

    assert.equals("POST", calls[1].method)
    assert.equals("/v1/public/review-requests-comments/100/replies", calls[1].path)
    assert.equals("200", result.id)
  end)

  async_tests.it("returned comment body matches response", function()
    local p, _ = make_provider({
      { response = raw_comment(201, "Reply content") },
    })

    local write_context = { pr_id = 42, diff_id = nil, diff_set_xid = nil, changelist = {} }
    local review = {
      pr = model.new_pr({
        id = "42",
        title = "t",
        state = "open",
        base_branch = "trunk",
        head_branch = "b",
        author = "a",
        url = "",
        review_status = "pending",
      }),
      head_sha = "",
      write_context = write_context,
    }
    local discussion = { id = "100", file = "f.lua", line = 1, resolved = false, comments = {} }
    local parent = model.new_comment({
      id = "100",
      author = "alice",
      body = model.new_body({ text = "root", format = "markdown" }),
      created_at = "",
      updated_at = "",
    })
    local body = model.new_body({ text = "Reply", format = "markdown" })

    local result = p:reply(review, discussion, parent, body)

    assert.equals("Reply content", result.body.text)
  end)
end)

-- ---------------------------------------------------------------------------
-- Suite: edit
-- ---------------------------------------------------------------------------

async_tests.describe("parley.providers.arcanum.provider — edit", function()
  async_tests.before_each(save_transport)
  async_tests.after_each(restore_transport)

  async_tests.it("calls PATCH endpoint with comment id", function()
    local p, calls = make_provider({
      { response = raw_comment(55, "Edited content") },
    })

    local write_context = { pr_id = 42, diff_id = nil, diff_set_xid = nil, changelist = {} }
    local review = {
      pr = model.new_pr({
        id = "42",
        title = "t",
        state = "open",
        base_branch = "trunk",
        head_branch = "b",
        author = "a",
        url = "",
        review_status = "pending",
      }),
      head_sha = "",
      write_context = write_context,
    }
    local body = model.new_body({ text = "Edited", format = "markdown" })

    local result = p:edit(review, "55", body)

    assert.equals("PATCH", calls[1].method)
    assert.equals("/v1/public/review-requests-comments/55", calls[1].path)
    assert.equals("55", result.id)
  end)
end)

-- ---------------------------------------------------------------------------
-- Suite: delete
-- ---------------------------------------------------------------------------

async_tests.describe("parley.providers.arcanum.provider — delete", function()
  async_tests.before_each(save_transport)
  async_tests.after_each(restore_transport)

  async_tests.it("calls DELETE endpoint with comment id", function()
    local p, calls = make_provider({
      { response = nil }, -- DELETE returns no body
    })

    local write_context = { pr_id = 42, diff_id = nil, diff_set_xid = nil, changelist = {} }
    local review = {
      pr = model.new_pr({
        id = "42",
        title = "t",
        state = "open",
        base_branch = "trunk",
        head_branch = "b",
        author = "a",
        url = "",
        review_status = "pending",
      }),
      head_sha = "",
      write_context = write_context,
    }

    p:delete(review, "77")

    assert.equals("DELETE", calls[1].method)
    assert.equals("/v1/public/review-requests-comments/77", calls[1].path)
  end)
end)

-- ---------------------------------------------------------------------------
-- Suite: stubs
-- ---------------------------------------------------------------------------

describe("parley.providers.arcanum.provider — stubs raise errors", function()
  local p

  before_each(function()
    p = arcanum.new({
      _auth = {
        read_token = function()
          return "token", nil
        end,
        read_token_async = function()
          return "token", nil
        end,
      },
      _sleep = function() end,
      _defer = function(cb, _)
        cb()
        return nil
      end,
      _get_config = function()
        return nil
      end,
    })
  end)

  it("resolve raises error", function()
    assert.has_error(function()
      p:resolve({}, "disc-1")
    end)
  end)

  it("unresolve raises error", function()
    assert.has_error(function()
      p:unresolve({}, "disc-1")
    end)
  end)

  it("react raises error", function()
    assert.has_error(function()
      p:react({}, "comment-1", "+1")
    end)
  end)

  it("submit_review raises error", function()
    assert.has_error(function()
      p:submit_review({}, "approve", model.new_body({ text = "", format = "markdown" }))
    end)
  end)

  it("progress_label returns host", function()
    assert.equals("arcanum.yandex.net", p:progress_label())
  end)
end)
