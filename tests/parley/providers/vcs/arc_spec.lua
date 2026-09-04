local vcs = require("parley.vcs")
local a = require("plenary.async.tests")

a.describe("VCS adapters", function()
  local saved
  local calls
  local results
  local arc = { vcs = "arc", root = "/checkout" }
  a.before_each(function()
    saved = vcs._runner
    vcs.reset_adapters()
    vcs.register_adapter("arc", require("parley.providers.vcs.arc"))
    calls, results = {}, {}
    vcs._runner = function(cmd, cwd)
      calls[#calls + 1] = { cmd = cmd, cwd = cwd }
      return table.remove(results, 1) or { code = 0, stdout = "", stderr = "" }
    end
  end)
  a.after_each(function()
    vcs._runner = saved
    vcs.reset_adapters()
  end)

  a.it("reads Arc revision content without Git or shell interpolation", function()
    results = { { code = 0, stdout = "content\n" } }
    assert.equals("content\n", vcs.read_file(arc, "abc", "a b.lua"))
    assert.same({ "arc", "show", "abc:a b.lua" }, calls[1].cmd)
    assert.equals("/checkout", calls[1].cwd)
  end)

  a.it("accepts a clean Arc file at the shared revision", function()
    results = { { code = 0, stdout = "abc\n" }, { code = 0, stdout = '{"status":{}}' } }
    assert.is_true(vcs.check_sync_state(arc, "a.lua", "abc").ok)
    assert.equals("arc", calls[2].cmd[1])
  end)

  for _, kind in ipairs({ "staged", "changed", "untracked", "unmerged" }) do
    a.it("rejects Arc " .. kind .. " changes", function()
      results = {
        { code = 0, stdout = "abc\n" },
        { code = 0, stdout = vim.json.encode({ status = { [kind] = { { path = "a.lua" } } } }) },
      }
      assert.is_false(vcs.check_sync_state(arc, "a.lua", "abc").ok)
    end)
  end

  a.it("fails closed for malformed status and missing revisions", function()
    assert.is_false(vcs.check_sync_state(arc, "a.lua", "").ok)
    assert.equals(0, #calls)
    results = { { code = 0, stdout = "abc" }, { code = 0, stdout = "{}" } }
    assert.is_false(vcs.check_sync_state(arc, "a.lua", "abc").ok)
  end)

  a.it("never defaults an unknown VCS to Git", function()
    assert.is_false(vcs.check_sync_state({ vcs = "unknown", root = "/x" }, "a", "abc").ok)
    assert.equals(0, #calls)
  end)

  a.it("validates every selected line and fails closed on diff errors", function()
    results = { { code = 0, stdout = "@@ -1 +1 @@\n@@ -3 +3 @@\n" } }
    assert.is_false(vcs.check_anchor_in_diff(arc, "trunk", "a", { start_line = 1, end_line = 3 }, "abc").ok)
    assert.same(
      { "arc", "diff", "--base", "--git", "--no-color", "--unified=0", "trunk", "abc", "--", "a" },
      calls[1].cmd
    )
    results = { { code = 1, stderr = "bad revision" } }
    assert.is_false(vcs.check_anchor_in_diff(arc, "trunk", "a", { start_line = 1 }, "abc").ok)
  end)
end)
