local target = require("parley.providers.arcanum.target")
local content = require("parley.local_content")
local vcs = require("parley.vcs")
describe("Arcanum review coordinates", function()
  local read, diff, contents, calls
  local review =
    { pr = { id = "1", base_branch = "trunk" }, head_sha = "source", base_sha = "base", review_sha = "merge" }
  local selection =
    { vcs_info = { vcs = "arc", root = "/arc" }, rel_path = "renamed", anchor = { start_line = 2, end_line = 3 } }
  before_each(function()
    read, diff = content.revision, vcs.read_diff
    contents = { source = "a\nb\nc\nd\n", merge = "upstream\na\nb\nc\nd\n" }
    calls = {}
    content.revision = function(_, revision, path)
      assert.equals("renamed", path)
      return contents[revision], "missing revision"
    end
    vcs.read_diff = function(_, base, path, head)
      calls = { base, path, head }
      return "@@ -2,0 +3,2 @@\n"
    end
  end)
  after_each(function()
    content.revision, vcs.read_diff = read, diff
  end)
  it("translates source ranges and validates against the immutable review diff", function()
    local result = target.validate({}, review, selection)
    assert.is_true(result.ok)
    assert.same({ start_line = 3, end_line = 4 }, result.anchor)
    assert.same({ "base", "renamed", "merge" }, calls)
    assert.equals(2, selection.anchor.start_line)
  end)
  it("rejects changed or noncontiguous ranges and missing revisions", function()
    for _, text in ipairs({ "a\nreplaced\nc\nd\n", "a\nb\ninserted\nc\nd\n" }) do
      contents.merge = text
      assert.is_false(target.validate({}, review, selection).ok)
    end
    contents.merge = nil
    assert.is_false(target.validate({}, review, selection).ok)
    local incomplete = vim.deepcopy(review)
    incomplete.base_sha = ""
    assert.is_false(target.validate({}, incomplete, selection).ok)
  end)
  it("rejects unchanged lines after translation", function()
    vcs.read_diff = function()
      return "@@ -1 +1 @@\n"
    end
    assert.is_false(target.validate({}, review, selection).ok)
  end)
  it("does not translate a selection already in the merge revision", function()
    local merged = vim.deepcopy(selection)
    merged.revision = "merge"
    merged.anchor = { start_line = 3, end_line = 4 }
    content.revision = function()
      error("already in review coordinates")
    end
    local result = target.validate({}, review, merged)
    assert.is_true(result.ok)
    assert.same(merged.anchor, result.anchor)
  end)
end)
