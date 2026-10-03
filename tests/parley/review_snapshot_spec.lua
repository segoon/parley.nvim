local provider = require("parley.provider")
describe("review snapshot identity", function()
  it("distinguishes diff changes with the same source head but ignores mutable caches", function()
    local review = {
      pr = { id = "42", base_branch = "trunk" },
      head_sha = "head",
      snapshot_id = "diff:1",
      write_context = { changelist = {} },
    }
    local other = vim.deepcopy(review)
    other.write_context.changelist.file = "entry"
    assert.is_true(provider.same_review(review, other))
    other.snapshot_id = "diff:2"
    assert.is_false(provider.same_review(review, other))
    assert.is_false(provider.same_review(nil, nil))
  end)
end)
