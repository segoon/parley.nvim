local mapping = require("parley.providers.arcanum.mapping")
local anchor = require("parley.anchor")
local model = require("parley.model")

--- @param id integer
--- @param parent? integer
--- @param side? string
--- @param diff? string
--- @return table
local function raw(id, parent, side, diff)
  return {
    id = id,
    reply_to_id = parent or vim.NIL,
    user = { name = "a" },
    content = "comment " .. id,
    created_at = "2026-01-01",
    issue_status = "open",
    anchor = {
      review_request = {
        id = 1,
        diff = {
          diff_set_xid = diff or "42",
          file = {
            entry_id = {
              content_id_before = { path = "old.lua", commit_id = "before" },
              content_id_after = { path = "new.lua", commit_id = "after" },
            },
            position = { side = side or "new", line = 3, size = 2 },
          },
        },
      },
    },
  }
end
local review = { head_sha = "head", write_context = { diff_id = 42 } }
--- @param comments table[]
--- @return table[]
local function group(comments)
  return mapping.group_comments_into_discussions(comments, "a", review)
end

describe("Arcanum discussion semantics", function()
  it("preserves and orders arbitrary-depth replies independently of input ordering", function()
    local a = group({ raw(3, 2), raw(2, 1), raw(1), raw(4, 1) })
    local b = group({ raw(4, 1), raw(1), raw(2, 1), raw(3, 2) })
    assert.same(a, b)
    assert.equals(1, #a)
    assert.same(
      { "1", "2", "3", "4" },
      vim.tbl_map(function(c)
        return c.id
      end, a[1].comments)
    )
    assert.equals("2", a[1].comments[3].parent_comment_id)
  end)
  it("groups orphans by missing ancestry and retains cycles without losing comments", function()
    local orphan = group({ raw(2, 99), raw(3, 2), raw(1, 99) })
    assert.equals(1, #orphan)
    assert.equals(3, #orphan[1].comments)
    assert.equals("missing_parent", orphan[1].ancestry)
    assert.equals("99", orphan[1].comments[1].parent_comment_id)
    local cycle = group({ raw(2, 1), raw(1, 2), raw(3, 2) })
    assert.equals(1, #cycle)
    assert.equals(3, #cycle[1].comments)
    assert.equals("cycle", cycle[1].ancestry)
  end)
  it("distinguishes current new-side anchors from old-side and historical anchors", function()
    local current, old, historical =
      group({ raw(1) })[1], group({ raw(2, nil, "old") })[1], group({ raw(3, nil, "new", "41") })[1]
    assert.equals("new.lua", current.file)
    assert.equals("old.lua", old.file)
    assert.equals("before", old.anchor.revision)
    assert.equals("old", old.anchor.side)
    assert.equals("42", current.anchor.diff_id)
    assert.equals("old.lua", current.anchor.before_path)
    assert.is_nil(current.anchor.unavailable_reason)
    assert.is_not_nil(old.anchor.unavailable_reason)
    assert.is_not_nil(historical.anchor.unavailable_reason)
  end)
  it("recognizes whole-file -1 and general anchors without inventing positions", function()
    local file, general = raw(1), raw(2)
    file.anchor.review_request.diff.file.position.line = -1
    general.anchor = { review_request = { id = 1 } }
    local a = group({ file, general })
    assert.equals("file", a[1].anchor.kind)
    assert.is_nil(a[1].line)
    assert.equals("general", a[2].anchor.kind)
    assert.is_nil(a[2].file)
    assert.is_nil(a[2].line)
  end)
  it("preserves deleted, encrypted and sparse anchors as unavailable", function()
    local deleted = raw(1, nil, "old")
    deleted.anchor.review_request.diff.file.entry_id.content_id_after = vim.NIL
    local d = group({ deleted })[1]
    assert.equals("old.lua", d.file)
    assert.is_nil(d.anchor.after_path)
    for _, value in ipairs({ vim.NIL, {}, { review_request = vim.NIL } }) do
      local c = raw(2)
      c.anchor = value
      assert.is_not_nil(group({ c })[1].anchor)
    end
    local encrypted = raw(3)
    encrypted.anchor.review_request.diff.file.diff_entry_encrypted = true
    assert.is_not_nil(group({ encrypted })[1].anchor.unavailable_reason)
  end)
  it("counts only explicitly open issues and preserves legacy boolean behavior", function()
    for _, status in ipairs({ "open", "resolved", "dropped", "not_issue", "unexpected", vim.NIL }) do
      local c = raw(1)
      c.issue_status = status
      local d = group({ c })[1]
      assert.equals(status == "open", model.is_open_issue(d))
      assert.equals(status == "resolved", d.resolved)
    end
    assert.is_true(model.is_open_issue({ resolved = false }))
  end)
  it("never projects old, historical or whole-file comments at the current head", function()
    local original, reads = anchor._diff, {}
    anchor._diff = function(_, revision, path)
      reads[#reads + 1] = { revision, path }
      return ""
    end
    local comments = { raw(1), raw(2, nil, "old"), raw(3, nil, "new", "41"), raw(4) }
    comments[4].anchor.review_request.diff.file.position.line = -1
    local ok, mapped = pcall(anchor.map_discussions, { vcs = "arc", root = "/repo" }, "head", group(comments))
    anchor._diff = original
    assert.is_true(ok, tostring(mapped))
    assert.same({ { "head", "new.lua" } }, reads)
    assert.equals(3, mapped["1"].local_line)
    for _, id in ipairs({ "2", "3", "4" }) do
      assert.is_nil(mapped[id].local_line)
    end
  end)
end)
