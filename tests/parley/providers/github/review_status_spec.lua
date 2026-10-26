local a = require("plenary.async.tests")
local github = require("parley.providers.github.provider")
local fixtures = require("tests.parley.providers.github.fixtures")

a.describe("GitHub aggregate review status", function()
  for _, case in ipairs({
    { name = "approval", value = "APPROVED", status = "approved" },
    { name = "changes requested", value = "CHANGES_REQUESTED", status = "changes_requested" },
    { name = "review required", value = "REVIEW_REQUIRED", status = "pending" },
    { name = "null decision", value = vim.NIL, status = "unknown" },
    { name = "empty decision", value = "", status = "unknown" },
    { name = "missing decision", status = "unknown" },
    { name = "future decision", value = "FUTURE", status = "unknown" },
    { name = "malformed decision", value = {}, status = "unknown" },
  }) do
    a.it("maps " .. case.name .. " without interpreting individual reviews", function()
      local raw = vim.json.decode(fixtures.PR_JSON)
      raw.reviewDecision = case.value
      raw.reviews = { { state = "APPROVED" }, { state = "COMMENTED" } }
      local p = github.new({
        repository = "owner/repo",
        _spawn = function(cmd, cb)
          if cmd[2] == "pr" then
            cb({ code = 0, stdout = vim.json.encode(raw) })
          elseif vim.tbl_contains(cmd, "/user") then
            cb({ code = 0, stdout = '{"login":"alice"}' })
          elseif vim.tbl_contains(cmd, "graphql") then
            cb({ code = 0, stdout = '[{"data":{}}]' })
          else
            assert.is_true(table.concat(cmd, " "):find("/comments", 1, true) ~= nil)
            cb({ code = 0, stdout = '[[{"id":1,"path":"a.lua","line":1,"body":"Readable"}]]' })
          end
        end,
      })
      local review = p:detect_pr("/repo", "feature")
      assert.equals(case.status, review.pr.review_status)
      assert.equals("Readable", p:fetch_discussions(review)[1].comments[1].body.text)
    end)
  end
end)
