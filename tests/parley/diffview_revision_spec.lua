local integration = require("parley.diffview_integration")
local contexts = require("parley.repositories.context")
describe("immutable diffview review coordinates", function()
  it("does not identity-map a source checkout onto a synthetic merge", function()
    assert.is_false(integration._is_head_side({ rev = { type = "LOCAL" } }, "merge", "source"))
    assert.is_false(integration._is_head_side({ rev = { type = "COMMIT", commit = "source" } }, "merge", "source"))
    assert.is_true(integration._is_head_side({ rev = { type = "COMMIT", commit = "merge" } }, "merge", "source"))
  end)
  it("drops identity mappings after refresh changes the merge revision", function()
    local get = contexts.get
    contexts.get = function()
      return { rel_path = "f", revision = "merge" }
    end
    local ok, err = pcall(function()
      local view = require("parley.repositories.review_view")({ _identity_bufnrs = { [1] = "new" } }, function()
        return true
      end)
      local shared = {
        review = { head_sha = "source", review_sha = "merge" },
        all_discussions = {
          {
            id = "thread",
            file = "f",
            line = 4,
            anchor = { kind = "inline", side = "new", path = "f", line = 4, revision = "merge" },
          },
        },
      }
      assert.equals(4, view(1, shared).mappings.thread.local_line)
      shared.review.review_sha = "next-merge"
      shared.all_discussions[1].anchor.revision = "next-merge"
      assert.is_nil(view(1, shared).mappings.thread)
    end)
    contexts.get = get
    assert.is_true(ok, tostring(err))
  end)
end)
