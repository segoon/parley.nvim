local contexts = require("parley.repositories.context")
local classifier = require("parley.buffer_context")
describe("immutable review buffer context", function()
  local classify, entries
  before_each(function()
    classify, entries = classifier.classify, contexts._entries
    contexts._entries = {}
  end)
  after_each(function()
    classifier.classify, contexts._entries = classify, entries
  end)
  it("revalidates the host checkout without losing the alias revision or path", function()
    contexts._entries[2] =
      { kind = "regular", host_bufnr = 1, rel_path = "other", revision = "merge", review_side = "new" }
    classifier.classify = function(bufnr)
      assert.equals(1, bufnr)
      return { kind = "regular", vcs_info = { vcs = "arc", root = "/arc", branch = "changed" } }
    end
    local result = contexts.refresh(2)
    assert.equals("merge", result.revision)
    assert.equals("other", result.rel_path)
    assert.equals("changed", result.vcs_info.branch)
  end)
end)
