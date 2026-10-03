local cli = require("parley.providers.arcanum.cli")

describe("Arcanum CLI requests", function()
  local saved, calls
  before_each(function()
    saved, calls = cli._system, {}
    cli._system = function(argv, opts, callback)
      calls[#calls + 1] = { argv = argv, opts = opts, callback = callback }
      return { kill = function() end }
    end
  end)
  after_each(function()
    cli._system = saved
  end)

  it("pins credentials and host and keeps literal bodies out of arguments", function()
    local body = "quotes ' and `ticks`\n$(literal)\n"
    local spec = cli.request("POST", "/v2/public/diff/42/comment", {
      content = body,
      entry_id = "opaque",
      side = "new",
      line = 7,
      size = 2,
    })
    cli.start(spec, "https://custom.example/api", "secret", 900, function() end)
    assert.same({
      "ya",
      "tool",
      "arcanum",
      "--json",
      "--api-url",
      "https://custom.example/api",
      "comment",
      "post-diff",
      "--diff-id",
      "42",
      "--entry-id",
      "opaque",
      "--line",
      "7",
      "--side",
      "new",
      "--size",
      "2",
      "--content-file",
      "/dev/stdin",
    }, calls[1].argv)
    assert.equals(body, calls[1].opts.stdin)
    assert.equals("secret", calls[1].opts.env.ARC_TOKEN)
    assert.equals("", calls[1].opts.env.ARCANUM_CLI_REVIEW_SYSTEM)
    assert.equals(900, calls[1].opts.timeout)
  end)

  it("preserves exact discovery filters and immutable revisions", function()
    local search = cli.request("POST", "/v1/pull-requests/cursor?fields=id,vcs(from_branch)", {
      offset = 100,
      limit = 100,
      desc_order = true,
      filter = { user_branch_prefix = "users/alice/topic", state = { published = true } },
    })
    assert.same({
      "pr",
      "list",
      "--from-branch",
      "users/alice/topic",
      "--published",
      "true",
      "--desc",
      "--limit",
      "100",
      "--offset",
      "100",
      "--fields",
      "id,vcs(from_branch)",
    }, search.args)
    local diff = cli.request("GET", "/v1/pull-requests/12/active-diff?fields=id,commit_ids(base,head,merge)")
    assert.same({ "pr", "active-diff", "--id", "12", "--fields", "id,commit_ids(base,head,merge)" }, diff.args)
  end)

  it("routes historical writes by PR and signed comment ID", function()
    for _, id in ipairs({ "-456", "123" }) do
      local reply = cli.request(
        "POST",
        "/v1/public/review-requests-comments/" .. id .. "/replies",
        { content = "reply" },
        { pr_id = 12 }
      )
      assert.same({ "comment", "reply", "--id", "12", "--reply-to", id, "--content-file", "/dev/stdin" }, reply.args)
      local resolve = cli.request(
        "PATCH",
        "/v1/public/review-requests-comments/" .. id,
        { issue_status = "resolved" },
        { pr_id = 12 }
      )
      assert.same({ "comment", "edit", "--id", "12", "--cid", id, "--issue-status", "resolved" }, resolve.args)
    end
  end)

  it("keeps full discussions, verdicts and unsupported reaction codes on HTTP", function()
    assert.is_nil(cli.request("GET", "/v1/public/review-requests/12/comments"))
    assert.is_nil(cli.request("GET", "/v1/plugin/pull-request/12/review"))
    assert.is_nil(cli.request("DELETE", "/v1/plugin/pull-request/12/comment/1/reaction/.."))
  end)

  it("uses a literal empty argument for empty edits", function()
    local spec = cli.request("PATCH", "/v1/public/review-requests-comments/-3", { content = "" }, { pr_id = 12 })
    assert.equals("--content=", spec.args[#spec.args])
    assert.is_nil(spec.stdin)
  end)

  it("selects CLI deletion, exact issue state, and reaction removal for historical IDs", function()
    assert.same(
      { "comment", "delete", "--id", "12", "--cid", "123" },
      cli.request("DELETE", "/v1/public/review-requests-comments/123", nil, { pr_id = 12 }).args
    )
    assert.same(
      { "comment", "remove-reaction", "--id", "12", "--cid", "-456", "--code", ":+1:" },
      cli.request("DELETE", "/v1/plugin/pull-request/12/comment/-456/reaction/%3A%2B1%3A").args
    )
    assert.same({
      "pr",
      "changelist",
      "--diff-id",
      "42",
      "--diff-mode",
      "flat_path",
      "--ignorews=false",
      "--fields",
      "path,entry_id",
    }, cli.request("GET", "/v2/public/diff/42/changelist?fields=path,entry_id").args)
  end)

  it("reports a missing executable without exposing credentials", function()
    cli._system = function()
      error("secret")
    end
    local result
    cli.start({ args = { "pr", "get" } }, "https://host/api", "secret", 900, function(r)
      result = r
    end)
    assert.is_false(result.ok)
    assert.is_false(result.sent)
    assert.is_nil(result.err:find("secret", 1, true))
    assert.matches("Cannot start", result.err)
  end)

  it("reports a process timeout as an uncertain write outcome", function()
    local result
    cli.start({ args = { "comment", "reply" } }, "https://host/api", "secret", 900, function(r)
      result = r
    end)
    calls[1].callback({ code = 124, stdout = "", stderr = "" })
    assert.is_true(result.timed_out)
    assert.is_true(result.uncertain)
    assert.matches("timed out", result.err)
  end)

  it("preserves structured error status without retrying a mutation", function()
    local result
    cli.start({ args = { "comment", "delete" } }, "https://host/api", "secret", 900, function(r)
      result = r
    end)
    calls[1].callback({
      code = 65,
      stdout = vim.json.encode({
        error = {
          code = "CONFLICT",
          http_status = 409,
          message = "conflict",
        },
      }),
      stderr = "",
    })
    assert.is_false(result.ok)
    assert.equals(409, result.status)
    assert.equals(1, #calls)
  end)
end)
