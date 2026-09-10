local content = require("parley.local_content")
local anchor = require("parley.anchor")
local projections = require("parley.repositories.local_mappings")
local a = require("plenary.async.tests")

a.describe("local content mapping", function()
  local saved
  local buffers
  a.before_each(function()
    saved = content._read_revision
    content._revisions, projections._entries = {}, {}
    buffers = {}
  end)
  a.after_each(function()
    content._read_revision = saved
    for _, buf in ipairs(buffers) do
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)
  --- @param path string
  --- @param lines string[]
  --- @return integer
  local function buffer(path, lines)
    local buf = vim.api.nvim_create_buf(true, false)
    buffers[#buffers + 1] = buf
    vim.api.nvim_buf_set_name(buf, path)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    return buf
  end

  a.it("maps unsaved buffer content and reuses immutable revision text", function()
    local reads = 0
    content._read_revision = function()
      reads = reads + 1
      return "one\ntwo\n"
    end
    local buf = buffer("/tmp/parley-map-a/f", { "insert", "one", "two" })
    local info = { vcs = "arc", root = "/tmp/parley-map-a" }
    assert.equals(3, anchor.map_line(info, "rev", "f", 2).local_line)
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, {})
    assert.equals(2, anchor.map_line(info, "rev", "f", 2).local_line)
    assert.equals(1, reads)
  end)

  a.it("isolates two checkouts sharing a remote review", function()
    content._read_revision = function()
      return "one\ntwo\n"
    end
    buffer("/tmp/parley-map-a/f", { "insert", "one", "two" })
    buffer("/tmp/parley-map-b/f", { "one", "two" })
    local shared = { head_sha = "rev", all_discussions = { { id = "d", file = "f", line = 2 } } }
    local first = projections.get({ vcs_info = { vcs = "arc", root = "/tmp/parley-map-a" } }, shared)
    local second = projections.get({ vcs_info = { vcs = "arc", root = "/tmp/parley-map-b" } }, shared)
    assert.equals(3, first.d.local_line)
    assert.equals(2, second.d.local_line)
  end)

  a.it("discards mapping results when a buffer changes during revision lookup", function()
    local buf = buffer("/tmp/parley-map-a/f", { "one", "two" })
    content._read_revision = function()
      vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "insert" })
      return "one\ntwo\n"
    end
    local ctx = { vcs_info = { vcs = "arc", root = "/tmp/parley-map-a" } }
    assert.is_nil(projections.get(ctx, { head_sha = "rev", all_discussions = { { id = "d", file = "f", line = 2 } } }))
  end)

  a.it("normalizes CRLF while preserving blank lines and final newline", function()
    assert.equals("a\n\n", content.normalize("a\r\n\r\n"))
    assert.equals("a", content.normalize("a"))
  end)

  a.it("debounces local remapping without invoking a remote refresh", function()
    local reviews = require("parley.repositories.review")
    local contexts = require("parley.repositories.context")
    local buf = buffer("/tmp/parley-map-a/f", { "one", "two" })
    local reads, publications = 0, 0
    content._read_revision = function()
      reads = reads + 1
      return "one\ntwo\n"
    end
    contexts._entries[buf] =
      { kind = "regular", rel_path = "f", vcs_info = { vcs = "arc", root = "/tmp/parley-map-a" } }
    reviews._seed(buf, { head_sha = "rev", all_discussions = { { id = "d", file = "f", line = 2 } } }, "local/remap")
    local unsubscribe = reviews.subscribe(buf, function(snapshot)
      publications = publications + 1
      assert.equals(3, snapshot.all_mappings.d.local_line)
    end)
    local old_refresh = reviews.refresh
    reviews.refresh = function()
      error("local edits must not refresh remote data")
    end
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "insert" })
    reviews.remap_async(buf)
    reviews.remap_async(buf)
    local done = vim.wait(500, function()
      return publications == 1
    end)
    reviews.refresh = old_refresh
    unsubscribe()
    reviews.detach(buf)
    contexts._entries[buf] = nil
    assert.is_true(done)
    assert.equals(1, reads)
  end)

  a.it("cancels pending local work when its buffer is detached", function()
    local reviews = require("parley.repositories.review")
    local contexts = require("parley.repositories.context")
    local buf = buffer("/tmp/parley-map-a/f", { "one" })
    local reads = 0
    content._read_revision = function()
      reads = reads + 1
      return "one\n"
    end
    contexts._entries[buf] =
      { kind = "regular", rel_path = "f", vcs_info = { vcs = "arc", root = "/tmp/parley-map-a" } }
    reviews._seed(buf, { head_sha = "rev", all_discussions = { { id = "d", file = "f", line = 1 } } }, "local/remap")
    reviews.remap_async(buf)
    reviews.detach(buf)
    vim.wait(200, function()
      return false
    end)
    contexts._entries[buf] = nil
    assert.equals(0, reads)
  end)
end)
