local eligibility = require("parley.providers.comment_target")
local vcs = require("parley.vcs")

describe("provider changed-line eligibility", function()
  local saved
  before_each(function()
    saved = vcs.read_diff
  end)
  after_each(function()
    vcs.read_diff = saved
  end)
  it("accepts changed lines and rejects unchanged lines in a range", function()
    vcs.read_diff = function()
      return "@@ -1,0 +2,2 @@\n+a\n+b"
    end
    local review = { pr = { base_branch = "main" }, head_sha = "rev" }
    local target = { vcs_info = {}, rel_path = "file", anchor = { start_line = 2 } }
    assert.is_true(eligibility.validate(nil, review, target).ok)
    target.anchor.end_line = 4
    assert.is_false(eligibility.validate(nil, review, target).ok)
  end)
end)
