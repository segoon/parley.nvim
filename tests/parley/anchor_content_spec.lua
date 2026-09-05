local anchor = require("parley.anchor")
local a = require("plenary.async.tests")

a.describe("content anchoring", function()
  local saved
  a.before_each(function()
    saved = anchor._diff
  end)
  a.after_each(function()
    anchor._diff = saved
  end)

  a.it("retains a stale approximation when content is unavailable", function()
    anchor._diff = function()
      return nil, "missing revision"
    end
    local result = anchor.map_line({ vcs = "arc", root = "/arc" }, "abc", "f", 10)
    assert.equals(10, result.local_line)
    assert.equals(0, result.confidence)
    assert.is_true(result.stale)
    assert.equals("missing revision", result.error)
  end)

  a.it("maps insertions after a line without shifting that line", function()
    anchor._diff = function()
      return "@@ -1,0 +2,1 @@\n"
    end
    local result = anchor.map_discussions({ vcs = "arc", root = "/arc" }, "abc", {
      { id = "one", file = "f", line = 1 },
      { id = "two", file = "f", line = 2 },
    })
    assert.equals(1, result.one.local_line)
    assert.equals(3, result.two.local_line)
  end)

  a.it("skips non-file anchors and batches reads by file", function()
    local count = 0
    anchor._diff = function()
      count = count + 1
      return ""
    end
    local result = anchor.map_discussions({ vcs = "arc", root = "/arc" }, "abc", {
      { id = "general", file = "", line = 0 },
      { id = "a", file = "f", line = 1 },
      { id = "b", file = "f", line = 3 },
    })
    assert.is_nil(result.general.local_line)
    assert.is_truthy(result.general.unavailable_reason)
    assert.equals(1, count)
  end)

  a.it("marks a range stale when any covered line changes", function()
    anchor._diff = function()
      return "@@ -3 +3 @@\n"
    end
    local result = anchor.map_discussions({ vcs = "arc", root = "/arc" }, "abc", {
      { id = "range", file = "f", line = 1, end_line = 5 },
    })
    assert.is_true(result.range.stale)
  end)
end)
