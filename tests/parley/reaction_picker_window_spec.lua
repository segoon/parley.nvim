--- tests/parley/reaction_picker_window_spec.lua — visual reaction picker popup.

local reaction_picker_window = require("parley.reaction_picker_window")

local saved = {}

local function save_seams()
  saved.get_config = reaction_picker_window._get_config
end

local function restore_seams()
  reaction_picker_window._get_config = saved.get_config
end

describe("parley.reaction_picker_window", function()
  before_each(function()
    save_seams()
    reaction_picker_window.close()
    reaction_picker_window._get_config = function()
      return {
        float = {
          border = "rounded",
          max_width = 80,
          max_height = 30,
        },
      }
    end
  end)

  after_each(function()
    reaction_picker_window.close()
    restore_seams()
  end)

  it("renders a focusable floating picker with reaction details", function()
    local source_winid = vim.api.nvim_get_current_win()

    reaction_picker_window.open({
      { reaction = "+1", emoji = "👍", label = "+1" },
      { reaction = "heart", emoji = "❤️", label = "heart", count = 2, viewer_reacted = true },
    }, {
      prompt = "Add reaction",
      source_winid = source_winid,
    }, function() end)

    assert.is_true(reaction_picker_window.is_open())
    assert.is_not_nil(reaction_picker_window._bufnr)
    assert.is_not_nil(reaction_picker_window._winid)
    assert.is_true(vim.api.nvim_win_is_valid(reaction_picker_window._winid))
    assert.equals(reaction_picker_window._winid, vim.api.nvim_get_current_win())
    assert.same(
      { "👍 +1", "❤️ heart x2 (you)" },
      vim.api.nvim_buf_get_lines(reaction_picker_window._bufnr, 0, -1, false)
    )
    assert.same({ 1, 0 }, vim.api.nvim_win_get_cursor(reaction_picker_window._winid))
  end)

  it("confirms the selected reaction and restores focus", function()
    local source_bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(source_bufnr)
    local source_winid = vim.api.nvim_get_current_win()
    local selected = nil

    reaction_picker_window.open({
      { reaction = "+1", emoji = "👍", label = "+1" },
      { reaction = "heart", emoji = "❤️", label = "heart" },
    }, {
      prompt = "Add reaction",
      source_winid = source_winid,
    }, function(item)
      selected = item
    end)

    reaction_picker_window.move(1)
    reaction_picker_window.confirm()

    assert.same({ reaction = "heart", emoji = "❤️", label = "heart" }, selected)
    assert.is_false(reaction_picker_window.is_open())
    assert.equals(source_winid, vim.api.nvim_get_current_win())
  end)

  it("cancels without a selection and restores focus", function()
    local source_bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(source_bufnr)
    local source_winid = vim.api.nvim_get_current_win()
    local selected = false

    reaction_picker_window.open({
      { reaction = "+1", emoji = "👍", label = "+1" },
    }, {
      prompt = "Add reaction",
      source_winid = source_winid,
    }, function(item)
      selected = item
    end)

    reaction_picker_window.cancel()

    assert.is_nil(selected)
    assert.is_false(reaction_picker_window.is_open())
    assert.equals(source_winid, vim.api.nvim_get_current_win())
  end)
end)
