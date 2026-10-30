local requests = require("parley.providers.arcanum.requests")

describe("explicit Arcanum operation requests", function()
  it("builds discovery and immutable diff reads directly as CLI commands", function()
    local lookup = requests.get_pr_by_branch("users/a/topic")
    assert.equals("cli", lookup.kind)
    assert.equals("read", lookup.retry_policy)
    assert.same({
      "pr",
      "get",
      "--from-branch",
      "users/a/topic",
      "--latest",
      "--repository",
      "arcadia",
      "--fields",
      "id,summary,status,url,author,vcs",
    }, lookup.args)
    assert.same(
      { "pr", "diff-info", "--diff-id", "42", "--fields", "id,pull_request_id" },
      requests.get_diff_info(42).args
    )
    assert.same(
      { "pr", "active-diff", "--id", "12", "--fields", "id,commit_ids(base,head,merge)" },
      requests.get_active_diff(12).args
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
    }, requests.get_changelist(42).args)
  end)

  it("keeps bodies literal and signed IDs scoped to their PR", function()
    local text = "quotes ' and `ticks`\n$(literal)"
    local reply = requests.reply(12, "-456", text, false)
    assert.equals("cli", reply.kind)
    assert.equals("create", reply.retry_policy)
    assert.equals(text, reply.stdin)
    assert.same({ "comment", "reply", "--id", "12", "--reply-to", "-456", "--content-file", "/dev/stdin" }, reply.args)
    assert.same(
      { "comment", "edit", "--id", "12", "--cid", "-456", "--content=" },
      requests.edit_comment(12, "-456", "").args
    )
    assert.same({ "comment", "delete", "--id", "12", "--cid", "-456" }, requests.delete_comment(12, "-456").args)
    assert.same(
      { "comment", "edit", "--id", "12", "--cid", "42", "--issue-status", "resolved" },
      requests.set_issue_state(12, "42", "resolved").args
    )
    local read = requests.get_comment(12, "-456")
    assert.equals("get", read.args[2])
    assert.equals("-456", read.args[6])
    assert.equals("read", read.retry_policy)
  end)

  it("selects keyed HTTP creation before execution only when requested", function()
    local body =
      { entry_id = "opaque", line = 7, size = 2, side = "new", content = "hello", is_draft = false, is_issue = false }
    local cli = requests.create_inline(12, 42, body, false)
    assert.equals("cli", cli.kind)
    assert.same({
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
    }, cli.args)
    local keyed = { requests.create_inline(12, 42, body, true), requests.reply(12, "-456", "hello", true) }
    for _, request in ipairs(keyed) do
      assert.equals("http", request.kind)
      assert.equals("POST", request.method)
      assert.equals("create", request.retry_policy)
      assert.equals("hello", request.body.content)
      assert.is_nil(request.args)
    end
  end)

  it("retains full discussions and every review verdict on HTTP", function()
    local discussions = requests.get_discussions(12)
    assert.equals("http", discussions.kind)
    assert.equals("/v1/public/review-requests/12/comments", discussions.path)
    assert.equals("read", discussions.retry_policy)
    assert.equals("http", requests.get_review(12).kind)
    for action, expected in pairs({
      ship = { "PUT", "/ship?sticky=false" },
      sticky_ship = { "PUT", "/ship?sticky=true" },
      unship = { "DELETE", "/ship" },
      block_merge = { "PUT", "/block-merge" },
      unblock_merge = { "DELETE", "/block-merge" },
    }) do
      local request = requests.apply_review_action(12, action)
      assert.equals("http", request.kind)
      assert.equals(expected[1], request.method)
      assert.equals("/v1/plugin/pull-request/12/review" .. expected[2], request.path)
      assert.equals("none", request.retry_policy)
    end
  end)

  it("sends ordinary opaque reaction codes to CLI and exceptional removals to HTTP", function()
    for _, present in ipairs({ true, false }) do
      local request = requests.set_reaction(12, "-42", "a/b?", present)
      assert.equals("cli", request.kind)
      assert.equals("a/b?", request.args[8])
      assert.equals("none", request.retry_policy)
    end
    for _, code in ipairs({ ".", "..", " " }) do
      local request = requests.set_reaction(12, "-42", code, false)
      assert.equals("http", request.kind)
      assert.equals("DELETE", request.method)
      assert.is_nil(request.args)
    end
  end)
end)
