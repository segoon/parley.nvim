local github = require("parley.providers.github.provider")
local transport = require("parley.providers.github.transport")

describe("GitHub review-status degradation", function()
  local available
  before_each(function()
    available = transport._gh_available
    transport._gh_available = true
  end)
  after_each(function()
    transport._gh_available = available
  end)

  for _, case in ipairs({
    { name = "HTTP failure", response = { code = 1, stdout = "", stderr = "HTTP 503" }, status = "unknown" },
    { name = "invalid JSON", response = { code = 0, stdout = "invalid" }, status = "unknown" },
    { name = "null", response = { code = 0, stdout = "null" }, status = "unknown" },
    { name = "object", response = { code = 0, stdout = '{"message":"unavailable"}' }, status = "unknown" },
    { name = "null item", response = { code = 0, stdout = "[null]" }, status = "unknown" },
    { name = "missing state", response = { code = 0, stdout = "[{}]" }, status = "unknown" },
    { name = "future state", response = { code = 0, stdout = '[{"state":"FUTURE"}]' }, status = "unknown" },
    { name = "empty reviews", response = { code = 0, stdout = "[]" }, status = "pending" },
    { name = "approved", response = { code = 0, stdout = '[{"state":"APPROVED"}]' }, status = "approved" },
  }) do
    it("keeps discussions readable after " .. case.name, function()
      local provider = github.new({
        repository = "owner/repo",
        config = { retry_count = 0 },
        _runner = function(cmd)
          local args = table.concat(cmd, " ")
          if args:find("/reviews", 1, true) then
            return case.response
          elseif args:find("/pulls?", 1, true) then
            return { code = 0, stdout = '[{"number":42,"head":{"sha":"head"},"base":{"ref":"main"}}]' }
          elseif args:find("/comments", 1, true) then
            return { code = 0, stdout = '[{"id":1,"path":"a.lua","line":1,"body":"Readable"}]' }
          elseif cmd[2] == "config" then
            return { code = 0, stdout = "viewer" }
          end
          return { code = 0, stdout = "{}" }
        end,
      })
      local review = provider:detect_pr("/repo", "feature")
      assert.equals("42", review.pr.id)
      assert.equals(case.status, review.pr.review_status)
      assert.equals("Readable", provider:fetch_discussions(review)[1].comments[1].body.text)
    end)
  end
end)
