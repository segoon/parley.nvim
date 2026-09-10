local periodic = require("parley.periodic_refresh")
local reviews = require("parley.repositories.review")
local read = require("parley.services.read")
local write = require("parley.services.write")
local window = require("parley.discussion_window")

describe("periodic review eligibility", function()
  local saved, buffers, wins, other_tab
  before_each(function()
    saved = { reviews.get, reviews.activity, read.is_refreshing, write.is_busy, window.resolve_source_bufnr }
    buffers, wins = {}, {}
    for i = 1, 3 do
      buffers[i] = vim.api.nvim_create_buf(false, true)
    end
    vim.api.nvim_set_current_buf(buffers[1])
    vim.cmd("vsplit")
    vim.api.nvim_set_current_buf(buffers[2])
    wins[1] = vim.api.nvim_get_current_win()
    vim.cmd("tabnew")
    other_tab = vim.api.nvim_get_current_tabpage()
    vim.api.nvim_set_current_buf(buffers[3])
    vim.cmd("tabprevious")
    reviews.get = function(buf)
      return vim.tbl_contains(buffers, buf) and { review = { pr = { id = "12" } } } or nil
    end
    reviews.activity = function(buf)
      if vim.tbl_contains(buffers, buf) then
        return { key = buf == buffers[3] and "hidden" or "shared", in_flight = false, buffers = buffers }
      end
    end
    read.is_refreshing = function()
      return false
    end
    write.is_busy = function()
      return false
    end
  end)
  after_each(function()
    reviews.get, reviews.activity, read.is_refreshing, write.is_busy, window.resolve_source_bufnr = unpack(saved)
    if vim.api.nvim_tabpage_is_valid(other_tab) then
      vim.api.nvim_set_current_tabpage(other_tab)
      vim.cmd("tabclose!")
    end
    for _, win in ipairs(wins) do
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end
    for _, buf in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
  end)
  it("deduplicates visible reviews and excludes other tabs", function()
    local items = periodic._candidates()
    assert.equals(1, #items)
    assert.equals("shared", items[1].key)
  end)
  it("includes a visible discussion's source buffer", function()
    window.resolve_source_bufnr = function(buf)
      return buf == buffers[2] and buffers[3] or buf
    end
    assert.equals(2, #periodic._candidates())
  end)
  it("skips a review when a hidden associated buffer is reading or writing", function()
    read.is_refreshing = function(buf)
      return buf == buffers[3]
    end
    assert.same({}, periodic._candidates())
    read.is_refreshing = function()
      return false
    end
    write.is_busy = function(buf)
      return buf == buffers[3]
    end
    assert.same({}, periodic._candidates())
  end)
  it("does not discover absent reviews and rejects changed membership", function()
    reviews.get = function()
      return nil
    end
    assert.same({}, periodic._candidates())
    assert.is_false(periodic._eligible({ bufnr = buffers[1], key = "old" }))
  end)
  it("checks visibility again before refreshing a queued candidate", function()
    local item = periodic._candidates()[1]
    vim.api.nvim_set_current_tabpage(other_tab)
    assert.is_false(periodic._eligible(item))
    vim.cmd("tabprevious")
  end)
end)
