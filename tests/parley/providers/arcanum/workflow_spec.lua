local a = require("plenary.async.tests")
local descriptor = require("parley.providers.arcanum.descriptor")
local http = require("parley.http")
local scheduler = require("parley.providers.arcanum.scheduler")
a.describe("configured Arcanum workflow", function()
  local saved, calls
  before_each(function()
    saved, calls = http.start, {}
    scheduler.reset()
    http.start = function(opts, callback)
      calls[#calls + 1] = opts
      assert.matches("^https://configured.example:8443/api/", opts.url)
      assert.equals("OAuth test-token", opts.headers.Authorization)
      assert.is_true(opts.timeout_ms > 0 and opts.timeout_ms <= 500)
      local path = opts.url:match("/api(.*)")
      local data
      if path == "/v2/users/me?fields=name" then
        data = { name = "api-user" }
      elseif path == "/v1/pull-requests/cursor" then
        data = { pull_requests = { { id = 1 } }, has_next = false }
      elseif path:find("active-diff", 1, true) then
        data = { id = 2, commit_ids = { head = "head" } }
      elseif path:find("/v1/pull-requests/1?", 1, true) then
        data = { id = 1, vcs = { from_branch = "feature" } }
      elseif path == "/v1/public/review-requests/1/comments" then
        data = {}
      else
        data = { id = 1, content = "reply", user = { name = "api-user" }, created_at = "now" }
      end
      callback({
        ok = true,
        sent = true,
        response = { ok = true, status = 200, headers = {}, body = vim.json.encode({ data = data }) },
      })
      return { cancel = function() end }
    end
  end)
  after_each(function()
    http.start = saved
    scheduler.reset()
  end)
  a.it("uses the configured host and credentials for verification, discovery, reads, and writes", function()
    local auth = {
      read_token = function()
        return "test-token"
      end,
    }
    local settings = { host = "configured.example:8443", timeout_ms = 500, request_interval_ms = 1 }
    local p = descriptor.factory({ login = "local-user", _auth = auth }, settings)
    local review = p:detect_pr("/checkout", "feature")
    assert.same({}, p:fetch_discussions(review))
    assert.is_true(p:reply(review, {}, { id = "1" }, { text = "reply" }).is_own)
    p:resolve(review, "1")
    assert.equals(7, #calls)
    assert.equals("configured.example:8443", p:cache_identity().host)
  end)
end)
