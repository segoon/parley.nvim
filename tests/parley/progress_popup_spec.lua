--- tests/parley/progress_popup_spec.lua — bottom-right progress popup.

local progress_popup = require("parley.progress_popup")
local progress_state = require("parley.ui_states.progress")

local saved = {}

local function save_seams()
  saved.get_config = progress_popup._get_config
  saved.new_timer = progress_popup._new_timer
end

local function restore_seams()
  progress_popup._get_config = saved.get_config
  progress_popup._new_timer = saved.new_timer
end

describe("parley.progress_popup", function()
  before_each(function()
    save_seams()
    progress_state.clear()
    progress_popup.teardown()
    progress_popup._get_config = function()
      return {
        progress = {
          enabled = true,
          border = "rounded",
          max_width = 60,
          max_height = 8,
          margin_bottom = 1,
          margin_right = 2,
          spinner_interval = 100,
        },
      }
    end
  end)

  after_each(function()
    progress_state.clear()
    progress_popup.teardown()
    restore_seams()
  end)

  it("renders stacked entries in a bottom-right popup", function()
    progress_popup.setup()

    progress_state.upsert({
      id = "1",
      bufnr = 1,
      title = "Parley",
      message = "Comment sent",
      kind = "write",
      state = "success",
      started_at = 1,
      updated_at = 1,
    })
    progress_state.upsert({
      id = "2",
      bufnr = 2,
      title = "Parley",
      message = "Reply failed",
      kind = "write",
      state = "failed",
      started_at = 2,
      updated_at = 2,
    })

    assert.is_not_nil(progress_popup._winid)
    assert.is_true(vim.api.nvim_win_is_valid(progress_popup._winid))
    assert.same(
      { "+ Parley  Comment sent", "! Parley  Reply failed" },
      vim.api.nvim_buf_get_lines(progress_popup._bufnr, 0, -1, false)
    )

    local cfg = vim.api.nvim_win_get_config(progress_popup._winid)
    assert.equals("editor", cfg.relative)
    assert.equals("SE", cfg.anchor)
    assert.is_not_nil(cfg.border)
  end)

  it("closes the popup when progress becomes empty", function()
    progress_popup.setup()

    progress_state.upsert({
      id = "1",
      bufnr = 1,
      title = "Parley",
      message = "Comment sent",
      kind = "write",
      state = "success",
      started_at = 1,
      updated_at = 1,
    })
    assert.is_true(vim.api.nvim_win_is_valid(progress_popup._winid))

    progress_state.clear()

    assert.is_nil(progress_popup._winid)
    assert.is_nil(progress_popup._bufnr)
  end)
end)
