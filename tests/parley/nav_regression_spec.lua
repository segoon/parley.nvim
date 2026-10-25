local nav = require("parley.nav")
local contexts = require("parley.repositories.context")
local reviews = require("parley.repositories.review")

describe("review navigation locations", function()
  local root, source, win, saved, opened
  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    local lines = {}
    for i = 1, 20 do
      lines[i] = tostring(i)
    end
    for _, name in ipairs({ "a.lua", "b.lua", "c.lua" }) do
      vim.fn.writefile(lines, root .. "/" .. name)
    end
    vim.cmd.edit(root .. "/b.lua")
    source, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
    contexts.set(source, { rel_path = "b.lua", vcs_info = { root = root, vcs = "git" } })
    saved = {
      window = package.loaded["parley.discussion_window"],
      helpers = package.loaded["parley.discussion_window.window"],
    }
    opened = nil
    package.loaded["parley.discussion_window"] = {
      resolve_source_bufnr = function()
        return source
      end,
      close = function() end,
      open_current_line = function(buf, opts)
        opened = { bufnr = buf, line = opts.cursor_line }
      end,
    }
    package.loaded["parley.discussion_window.window"] = {
      resolve_source_winid = function()
        return win
      end,
    }
  end)
  after_each(function()
    package.loaded["parley.discussion_window"] = saved.window
    package.loaded["parley.discussion_window.window"] = saved.helpers
    contexts.invalidate(source)
    reviews.detach(source)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(buf):sub(1, #root + 1) == root .. "/" then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
    vim.fn.delete(root, "rf")
  end)

  --- @param entries table[]
  local function seed(entries)
    local mappings = {}
    for _, entry in ipairs(entries) do
      entry.comments = {}
      mappings[entry.id] = { local_line = entry.local_line or entry.line }
    end
    reviews._seed(source, {
      review = { pr = { id = "42" }, head_sha = "head" },
      all_discussions = entries,
      all_mappings = mappings,
    })
  end

  for _, cursor in ipairs({ 7, 15 }) do
    it("selects the nearest preceding discussion from line " .. cursor, function()
      seed({ { id = "1", file = "b.lua", line = 3 }, { id = "2", file = "b.lua", line = 10 } })
      vim.api.nvim_win_set_cursor(win, { cursor, 0 })
      nav.review_prev(source)
      assert.equals(cursor == 7 and 3 or 10, vim.api.nvim_win_get_cursor(win)[1])
    end)
  end

  it("uses mapped positions and skips the cursor's own location", function()
    seed({
      { id = "1", file = "b.lua", line = 3, local_line = 5 },
      { id = "2", file = "b.lua", line = 10, local_line = 12 },
    })
    vim.api.nvim_win_set_cursor(win, { 12, 0 })
    nav.review_prev(source)
    assert.equals(5, vim.api.nvim_win_get_cursor(win)[1])
  end)

  it("selects the preceding file when above the first discussion", function()
    seed({
      { id = "1", file = "a.lua", line = 3 },
      { id = "2", file = "b.lua", line = 10 },
      { id = "3", file = "c.lua", line = 15 },
    })
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    nav.review_prev(source)
    assert.equals(root .. "/a.lua", vim.api.nvim_buf_get_name(0))
  end)

  for _, direction in ipairs({ "review_next", "review_prev" }) do
    it("reopens the destination discussion after a float's " .. direction, function()
      seed({ { id = "1", file = "a.lua", line = 3 }, { id = "2", file = "b.lua", line = 10 } })
      vim.api.nvim_win_set_cursor(win, { 10, 0 })
      nav[direction](-1) -- Distinct from the source, like a discussion float.
      assert.is_true(vim.wait(500, function()
        return opened ~= nil
      end))
      assert.equals(root .. "/a.lua", vim.api.nvim_buf_get_name(opened.bufnr))
      assert.equals(vim.api.nvim_win_get_buf(win), opened.bufnr)
      assert.equals(3, opened.line)
    end)
  end
end)
