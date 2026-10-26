local a = require("plenary.async.tests")
local github = require("parley.providers.github.provider")
local transport = require("parley.providers.github.transport")

---@return table
local function metadata()
  return {
    number = 42,
    title = "Feature",
    state = "OPEN",
    baseRefName = "main",
    headRefName = "feature",
    headRefOid = "head-sha",
    author = { login = "author" },
    url = "https://github.com/o/r/pull/42",
    reviewDecision = "REVIEW_REQUIRED",
  }
end

a.describe("GitHub CLI metadata", function()
  local available
  a.before_each(function()
    available, transport._gh_available = transport._gh_available, true
  end)
  a.after_each(function()
    transport._gh_available = available
  end)

  a.it("uses the authenticated viewer instead of a configured account and caches it", function()
    local calls = 0
    local p = github.new({
      repository = "o/r",
      _spawn = function(cmd, cb)
        calls = calls + 1
        assert.is_true(vim.tbl_contains(cmd, "/user"))
        cb({ code = 0, stdout = '{"login":"token-owner"}' })
      end,
      _runner = function()
        error("Do not read local account configuration")
      end,
    })
    transport.fetch_viewer_login(p)
    transport.fetch_viewer_login(p)
    assert.equals("token-owner", p._viewer_login)
    assert.equals(1, calls)
  end)

  a.it("fetches PR metadata and aggregate decision in one read with explicit repository routing", function()
    local calls = 0
    local p = github.new({
      repository = "o/r",
      host = "ghe.example.com",
      _spawn = function(cmd, cb)
        calls = calls + 1
        assert.same({ "gh", "pr", "view" }, { cmd[1], cmd[2], cmd[3] })
        assert.is_true(vim.tbl_contains(cmd, "feature"))
        assert.is_true(vim.tbl_contains(cmd, "ghe.example.com/o/r"))
        assert.is_false(vim.tbl_contains(cmd, "--hostname"))
        cb({ code = 0, stdout = vim.json.encode(metadata()) })
      end,
    })
    local review = p:detect_pr("/repo", "feature")
    assert.equals("42", review.pr.id)
    assert.equals("open", review.pr.state)
    assert.equals("author", review.pr.author)
    assert.equals("pending", review.pr.review_status)
    assert.equals("head-sha", review.head_sha)
    assert.same({ number = 42, head_sha = "head-sha" }, review.write_context)
    assert.equals(1, calls)
  end)

  a.it("treats only the CLI's missing-branch diagnostic as no PR", function()
    for _, case in ipairs({
      { message = 'no pull requests found for branch "feature"\n', absent = true },
      { message = "HTTP 401: Bad credentials", absent = false },
      { message = "GraphQL: Resource not accessible", absent = false },
    }) do
      local p = github.new({
        repository = "o/r",
        config = { retry_count = 0 },
        _spawn = function(_, cb)
          cb({ code = 1, stderr = case.message })
        end,
      })
      local ok, result = pcall(p.detect_pr, p, "/repo", "feature")
      assert.equals(case.absent, ok)
      if case.absent then
        assert.is_nil(result)
      end
    end
  end)

  a.it("stops reaction toggles when the authenticated viewer is unavailable", function()
    local calls = 0
    local p = github.new({
      repository = "o/r",
      _spawn = function(cmd, cb)
        calls = calls + 1
        assert.is_true(vim.tbl_contains(cmd, "/user"))
        cb({ code = 1, stderr = "HTTP 403" })
      end,
    })
    local ok, err = pcall(p.react, p, {}, "7", "+1")
    assert.is_false(ok)
    assert.matches("authenticated GitHub user", err, 1, true)
    assert.equals(1, calls)
  end)

  a.it("does not confuse malformed custom metadata with an absent PR", function()
    local p = github.new({
      repository = "o/r",
      api_base = "https://example.test/custom/api/v3",
      _spawn = function(cmd, cb)
        if vim.tbl_contains(cmd, "GET") then
          cb({ code = 0, stdout = '[{"number":42}]' })
        else
          cb({ code = 0, stdout = '{"data":{}}' })
        end
      end,
    })
    assert.has_error(function()
      p:detect_pr("/repo", "feature")
    end)
  end)

  a.it("ignores closed and merged PRs", function()
    for _, state in ipairs({ "CLOSED", "MERGED" }) do
      local raw = metadata()
      raw.state = state
      local p = github.new({
        repository = "o/r",
        _spawn = function(_, cb)
          cb({ code = 0, stdout = vim.json.encode(raw) })
        end,
      })
      assert.is_nil(p:detect_pr("/repo", "feature"))
    end
  end)

  a.it("preserves custom endpoints and numeric branch names using explicit API lookup", function()
    for _, case in ipairs({
      { api_base = "https://ghe.example.com/custom/api/v3", branch = "feature" },
      { branch = "123" },
    }) do
      local calls = 0
      local p = github.new({
        repository = "o/r",
        host = "ghe.example.com",
        api_base = case.api_base,
        _spawn = function(cmd, cb)
          calls = calls + 1
          assert.equals("api", cmd[2])
          if calls == 1 then
            assert.is_true(vim.tbl_contains(cmd, "head=o:" .. case.branch))
            assert.is_true(vim.tbl_contains(cmd, "GET"))
            cb({ code = 0, stdout = '[{"number":42}]' })
          else
            if case.api_base then
              assert.is_true(vim.tbl_contains(cmd, "https://ghe.example.com/custom/api/graphql"))
              assert.is_true(vim.tbl_contains(cmd, "variables[number]=42"))
            end
            local raw = metadata()
            raw.headRefName = case.branch
            cb({ code = 0, stdout = vim.json.encode({ data = { repository = { pullRequest = raw } } }) })
          end
        end,
      })
      local review = p:detect_pr("/repo", case.branch)
      assert.equals("42", review.pr.id)
      assert.equals(case.branch, review.pr.head_branch)
      assert.equals("pending", review.pr.review_status)
      assert.equals(2, calls)
    end
  end)
end)
