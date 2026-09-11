local window = require("parley.discussion_window.window")

describe("parley.discussion_window.window", function()
  local bufnr
  local instance

  before_each(function()
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    instance = {
      bufnr = bufnr,
      winid = vim.api.nvim_get_current_win(),
    }
  end)

  after_each(function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  it("maps gx to viewing the discussion", function()
    local viewed_bufnr
    window.write_lines(17, instance, { "Discussion" }, {
      on_close = function() end,
      on_reply = function() end,
      on_react = function() end,
      on_edit = function() end,
      on_delete = function() end,
      on_view = function(src_bufnr)
        viewed_bufnr = src_bufnr
      end,
    })

    local mapping
    for _, candidate in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
      if candidate.lhs == "gx" then
        mapping = candidate
        break
      end
    end

    assert.is_not_nil(mapping)
    assert.equals("Open Parley discussion in browser", mapping.desc)
    mapping.callback()
    assert.equals(17, viewed_bufnr)
  end)
end)
