local a = require("plenary.async.tests")
local anchor = require("parley.anchor")
local content = require("parley.local_content")

a.describe("structured local diff hunks", function()
  local cases = {
    {
      name = "insertion before anchor",
      before = "one\ntwo\n",
      after = { "one", "inserted", "two" },
      line = 2,
      mapped = 3,
    },
    { name = "insertion at start", before = "one\ntwo\n", after = { "new", "one", "two" }, line = 1, mapped = 2 },
    { name = "insertion at end", before = "one\ntwo\n", after = { "one", "two", "new" }, line = 2, mapped = 2 },
    { name = "deletion", before = "one\ntwo\nthree\n", after = { "one", "three" }, line = 2, stale = true },
    { name = "after deletion", before = "one\ntwo\nthree\n", after = { "one", "three" }, line = 3, mapped = 2 },
    { name = "replacement", before = "one\ntwo\n", after = { "one", "changed" }, line = 2, mapped = 2, stale = true },
    { name = "added final newline", before = "one\ntwo", after = { "one", "two" }, line = 2, mapped = 2, stale = true },
    { name = "CRLF", before = "one\r\ntwo\r\n", after = { "one", "two" }, line = 2, mapped = 2 },
  }
  for _, case in ipairs(cases) do
    a.it("maps " .. case.name .. " without parsing a generated patch", function()
      local old_read, old_parse = content._read_revision, anchor.parse_hunks
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, "/tmp/parley-structured-hunks/f")
      vim.bo[buf].buftype = ""
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, case.after)
      content._revisions = {}
      content._read_revision = function()
        return case.before
      end
      anchor.parse_hunks = function()
        error("Local mapping must consume structured hunks")
      end
      local ok, err = pcall(function()
        local result = anchor.map_discussions({ vcs = "git", root = "/tmp/parley-structured-hunks" }, "rev", {
          { id = "anchor", file = "f", line = case.line },
        }).anchor
        assert.equals(case.mapped, result.local_line)
        assert.equals(case.stale or false, result.stale)
      end)
      content._read_revision, anchor.parse_hunks = old_read, old_parse
      content._revisions = {}
      vim.api.nvim_buf_delete(buf, { force = true })
      assert.is_true(ok, err)
    end)
  end
end)
