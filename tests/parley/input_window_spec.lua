--- tests/parley/input_window_spec.lua — Input draft window (Step 14)

local input_window = require("parley.input_window")

local saved = {}
local notify_calls = {}
local confirm_calls = {}

local function scratch()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(bufnr)
  return bufnr
end

local function cleanup_instances()
  for _, instance in pairs(input_window._instances) do
    instance.close(true)
  end
end

describe("parley.input_window", function()
  before_each(function()
    saved.notify = input_window._notify
    saved.confirm = input_window._confirm_discard
    notify_calls = {}
    confirm_calls = {}
    input_window._notify = function(msg, level)
      notify_calls[#notify_calls + 1] = { msg = msg, level = level }
    end
    input_window._confirm_discard = function(msg)
      confirm_calls[#confirm_calls + 1] = msg
      return false
    end
    cleanup_instances()
  end)

  after_each(function()
    cleanup_instances()
    input_window._notify = saved.notify
    input_window._confirm_discard = saved.confirm
  end)

  it("keeps a non-empty draft open when discard is rejected", function()
    local source_bufnr = scratch()
    local instance = input_window.open({
      kind = "new",
      title = "New comment",
      status = "Drafting...",
      source_bufnr = source_bufnr,
      on_submit = function() end,
    })

    vim.api.nvim_buf_set_lines(instance.bufnr, 0, -1, false, { "draft text" })

    assert.is_false(instance.request_close())
    assert.equals(1, #confirm_calls)
    assert.is_true(vim.api.nvim_win_is_valid(instance.winid))
  end)

  it("blocks close while submitting and allows explicit request cancellation", function()
    local source_bufnr = scratch()
    local instance = input_window.open({
      kind = "reply",
      title = "Reply",
      status = "Drafting...",
      source_bufnr = source_bufnr,
      on_submit = function() end,
    })

    local cancelled = false
    instance.set_cancel(function()
      cancelled = true
      instance.set_idle("Cancelled")
    end)
    instance.set_submitting("Replying...")

    assert.is_false(instance.request_close())
    assert.equals(1, #notify_calls)
    assert.is_false(vim.bo[instance.bufnr].modifiable)

    instance.cancel_request()

    assert.is_true(cancelled)
    assert.is_true(vim.bo[instance.bufnr].modifiable)
    local header = vim.api.nvim_buf_get_lines(instance.header_bufnr, 0, -1, false)
    assert.same({ "Cancelled" }, header)
  end)

  it("submits through a scheduled callback so header updates are allowed", function()
    local source_bufnr = scratch()
    local submitted = false
    local instance = input_window.open({
      kind = "new",
      title = "New comment",
      status = "Drafting...",
      source_bufnr = source_bufnr,
      on_submit = function(win, text)
        submitted = true
        assert.equals("draft text", text)
        win.set_submitting("Posting...")
      end,
    })

    vim.api.nvim_buf_set_lines(instance.bufnr, 0, -1, false, { "draft text" })
    instance.submit()

    assert.is_true(vim.wait(100, function()
      return submitted
    end))
    assert.is_false(vim.bo[instance.bufnr].modifiable)
    local header = vim.api.nvim_buf_get_lines(instance.header_bufnr, 0, -1, false)
    assert.same({ "Posting..." }, header)
  end)

  it("shows the send-key hint in the header", function()
    local source_bufnr = scratch()
    local instance = input_window.open({
      kind = "reply",
      title = "Reply",
      status = "Drafting reply. Press <C-s> to send, or <Esc>s in normal mode. q closes.",
      source_bufnr = source_bufnr,
      on_submit = function() end,
    })

    local header = vim.api.nvim_buf_get_lines(instance.header_bufnr, 0, -1, false)
    assert.same({ "Drafting reply. Press <C-s> to send, or <Esc>s in normal mode. q closes." }, header)
  end)
end)
