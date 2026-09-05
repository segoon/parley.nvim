local actions = require("parley.providers.arcanum.review_actions")
local provider = require("parley.providers.arcanum.provider")
local transport = require("parley.providers.arcanum.transport")

describe("Arcanum explicit review actions", function()
  local p, review, saved, calls, diff
  before_each(function()
    p = provider.new({ _auth = {
      read_token = function()
        return "token"
      end,
    } })
    dofile("tests/support/arcanum_session.lua")(p)
    review = {
      pr = { id = "12" },
      head_sha = "head",
      write_context = {
        pr_id = 12,
        diff_id = 34,
        review_data = { reviewers = {}, min_ships_required = 1 },
      },
    }
    saved = transport.http_start
    calls = {}
    diff = { id = 34, commit_ids = { head = "head" } }
    transport.http_start = function(_, method, path, body, callback, opts)
      calls[#calls + 1] = { method = method, path = path, body = body, opts = opts }
      callback({ ok = true, data = method == "GET" and diff or nil })
      return { cancel = function() end }
    end
  end)
  after_each(function()
    transport.http_start = saved
  end)
  it("normalizes actual verdicts and remaining approval requirements", function()
    assert.equals("pending", actions.status({ reviewers = {}, min_ships_required = 1 }))
    assert.equals("approved", actions.status({ reviewers = {}, min_ships_required = 0 }))
    assert.equals(
      "changes_requested",
      actions.status({
        reviewers = {
          { user = { name = "alice" }, action = "block_merge" },
        },
        min_ships_required = 0,
      })
    )
    for _, malformed in ipairs({
      {},
      { reviewers = {}, min_ships_required = -1 },
      { reviewers = { { user = {}, action = "approve" } }, min_ships_required = 0 },
    }) do
      assert.equals("unknown", actions.status(malformed))
    end
  end)
  it("rechecks the loaded diff and sends exact normal/sticky/block actions without retry", function()
    for _, case in ipairs({
      { "ship", "/ship?sticky=false" },
      { "sticky_ship", "/ship?sticky=true" },
      { "block_merge", "/block-merge" },
    }) do
      local result
      p:begin_review_action(review, case[1], function(r)
        result = r
      end)
      assert.is_true(result.ok)
      assert.equals("GET", calls[#calls - 1].method)
      assert.equals("PUT", calls[#calls].method)
      local expected_path = "/v1/plugin/pull-request/12/review" .. case[2]
      assert.equals(expected_path, calls[#calls].path)
      assert.same({ retry_policy = "none" }, calls[#calls].opts)
      assert.is_nil(calls[#calls].body)
    end
  end)
  it("requires the viewer's corresponding verdict before withdrawal", function()
    local result
    p:begin_review_action(review, "unship", function(r)
      result = r
    end)
    assert.is_false(result.ok)
    assert.equals(0, #calls)
    local withdrawals = { { "approve_pr", "unship", "/ship" }, { "block_merge", "unblock_merge", "/block-merge" } }
    for _, case in ipairs(withdrawals) do
      review.write_context.review_data.reviewers = { { user = { name = "alice" }, action = case[1] } }
      p:begin_review_action(review, case[2], function(r)
        result = r
      end)
      assert.is_true(result.ok)
      assert.equals("DELETE", calls[#calls].method)
      assert.equals("/v1/plugin/pull-request/12/review" .. case[3], calls[#calls].path)
    end
  end)
  it("aborts a changed diff before sending any mutation", function()
    diff.id = 35
    local result
    p:begin_review_action(review, "ship", function(r)
      result = r
    end)
    assert.is_false(result.ok)
    assert.matches("changed", result.err)
    assert.equals(1, #calls)
  end)
  it("disables actions when verdict data is unavailable", function()
    review.write_context.review_data = nil
    local choices, reason = p:review_actions(review)
    assert.equals(0, #choices)
    assert.matches("refresh", reason)
  end)
  it("cancels either stage exactly once and ignores late callbacks", function()
    for _, mutation in ipairs({ false, true }) do
      local pending, results, stopped = {}, {}, {}
      transport.http_start = function(_, method, _, _, cb)
        pending[#pending + 1] = cb
        return {
          cancel = function()
            stopped[#stopped + 1] = method
            cb({ ok = false, cancelled = true, uncertain = method ~= "GET" })
          end,
        }
      end
      local h = p:begin_review_action(review, "ship", function(r)
        results[#results + 1] = r
      end)
      if mutation then
        pending[1]({ ok = true, data = diff })
        pending[1]({ ok = true, data = diff })
        assert.equals(2, #pending)
      end
      h.cancel()
      for _, cb in ipairs(pending) do
        cb({ ok = true, data = diff })
      end
      assert.equals(1, #results)
      assert.is_true(results[1].cancelled)
      assert.equals(mutation, results[1].uncertain)
      assert.same({ mutation and "PUT" or "GET" }, stopped)
    end
  end)
  it("cancels the mutation handle when the recheck completed synchronously", function()
    local stopped, completed
    transport.http_start = function(_, method, _, _, cb)
      if method == "GET" then
        cb({ ok = true, data = diff })
      end
      return {
        cancel = function()
          stopped = method
          cb({ ok = false, cancelled = true, uncertain = method ~= "GET" })
        end,
      }
    end
    local h = p:begin_review_action(review, "ship", function(r)
      completed = r
    end)
    h.cancel()
    assert.equals("PUT", stopped)
    assert.is_true(completed.uncertain)
  end)
  it("rejects credentials changed during the recheck", function()
    transport.http_start = function(_, _, _, _, cb)
      p._auth.read_token = function()
        return "changed"
      end
      cb({ ok = true, data = diff })
      return { cancel = function() end }
    end
    local result
    p:begin_review_action(review, "ship", function(r)
      result = r
    end)
    assert.is_false(result.ok)
    assert.matches("credentials changed", result.err)
  end)
  it("loads unknown status safely after failed or malformed reads", function()
    local run = transport.http_run
    for _, failure in ipairs({ true, false }) do
      transport.http_run = function()
        if failure then
          error("403 secret server details")
        end
        return { reviewers = vim.NIL }
      end
      actions.load(p, review)
      assert.equals("unknown", review.pr.review_status)
      assert.is_nil(review.write_context.review_data)
    end
    transport.http_run = run
  end)
end)
