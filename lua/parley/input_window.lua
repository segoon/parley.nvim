--- parley.input_window — Markdown draft input float.

local M = {}

--- Active instances keyed by source buffer.
--- @type table<integer, parley.input_window.Instance>
M._instances = {}

--- Notify hook; replace in tests.
--- @type fun(msg: string, level: integer)
M._notify = function(msg, level)
  vim.notify(msg, level)
end

--- Confirm hook; replace in tests.
--- @type fun(msg: string): boolean
M._confirm_discard = function(msg)
  return vim.fn.confirm(msg, "&Discard\n&Keep editing", 2) == 1
end

--- @class parley.input_window.Instance
--- @field source_bufnr integer
--- @field header_bufnr integer
--- @field header_winid integer
--- @field bufnr integer
--- @field winid integer
--- @field state 'idle'|'submitting'
--- @field close fun(force?: boolean): boolean
--- @field request_close fun(): boolean
--- @field cancel_request fun(): nil
--- @field submit fun(): nil
--- @field set_submitting fun(status: string): nil
--- @field set_idle fun(status: string): nil
--- @field set_cancel fun(cancel: fun(): nil): nil

--- @param title string
--- @param width integer
--- @param height integer
--- @return vim.api.keyset.win_config, vim.api.keyset.win_config
local function make_win_configs(title, width, height)
  local total_height = height + 1
  local row = math.max(0, math.floor((vim.o.lines - total_height) / 2) - 1)
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))
  local header_cfg = {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = 1,
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "center",
    focusable = false,
  }
  local body_cfg = {
    relative = "editor",
    row = row + 1,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    focusable = true,
  }
  return header_cfg, body_cfg
end

--- @param instance parley.input_window.Instance
--- @return string
local function draft_text(instance)
  local lines = vim.api.nvim_buf_get_lines(instance.bufnr, 0, -1, false)
  return table.concat(lines, "\n")
end

--- @param instance parley.input_window.Instance
--- @return boolean
local function is_dirty(instance)
  return draft_text(instance):match("%S") ~= nil
end

--- @param instance parley.input_window.Instance
--- @param status string
local function set_header(instance, status)
  vim.bo[instance.header_bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(instance.header_bufnr, 0, -1, false, { status })
  vim.bo[instance.header_bufnr].modifiable = false
end

--- @param instance parley.input_window.Instance
--- @param status string
local function enter_submitting(instance, status)
  instance.state = "submitting"
  set_header(instance, status)
  vim.bo[instance.bufnr].modifiable = false
end

--- @param instance parley.input_window.Instance
--- @param status string
local function enter_idle(instance, status)
  instance.state = "idle"
  set_header(instance, status)
  vim.bo[instance.bufnr].modifiable = true
  if vim.api.nvim_win_is_valid(instance.winid) then
    vim.api.nvim_set_current_win(instance.winid)
  end
end

--- @param instance parley.input_window.Instance
--- @param force boolean
--- @return boolean
local function do_close(instance, force)
  if not force then
    if instance.state == "submitting" then
      M._notify("Parley request in progress. Press C to cancel the request.", vim.log.levels.WARN)
      return false
    end
    if is_dirty(instance) then
      local discard = M._confirm_discard("Are you sure? The draft is not saved and will be lost.")
      if not discard then
        return false
      end
    end
  end

  instance._closing = true
  M._instances[instance.source_bufnr] = nil
  if vim.api.nvim_win_is_valid(instance.winid) then
    vim.api.nvim_win_close(instance.winid, true)
  end
  if vim.api.nvim_win_is_valid(instance.header_winid) then
    vim.api.nvim_win_close(instance.header_winid, true)
  end
  if vim.api.nvim_buf_is_valid(instance.bufnr) then
    pcall(vim.api.nvim_buf_delete, instance.bufnr, { force = true })
  end
  if vim.api.nvim_buf_is_valid(instance.header_bufnr) then
    pcall(vim.api.nvim_buf_delete, instance.header_bufnr, { force = true })
  end
  return true
end

--- @param instance parley.input_window.Instance
local function reopen_after_forbidden_close(instance)
  local header_cfg, body_cfg = make_win_configs(instance._title, instance._width, instance._height)
  if vim.api.nvim_buf_is_valid(instance.header_bufnr) then
    instance.header_winid = vim.api.nvim_open_win(instance.header_bufnr, false, header_cfg)
  end
  if vim.api.nvim_buf_is_valid(instance.bufnr) then
    instance.winid = vim.api.nvim_open_win(instance.bufnr, true, body_cfg)
  end
end

--- Open an input float.
--- @param opts { kind: string, title: string, status: string, source_bufnr: integer, initial_text?: string, on_submit: fun(instance: parley.input_window.Instance, text: string): boolean|nil }
--- @return parley.input_window.Instance
function M.open(opts)
  local existing = M._instances[opts.source_bufnr]
  if existing and vim.api.nvim_win_is_valid(existing.winid) then
    vim.api.nvim_set_current_win(existing.winid)
    return existing
  end

  local width = math.min(90, math.max(50, math.floor(vim.o.columns * 0.6)))
  local height = math.min(12, math.max(6, math.floor(vim.o.lines * 0.25)))
  local header_cfg, body_cfg = make_win_configs(opts.title, width, height)
  local header_bufnr = vim.api.nvim_create_buf(false, true)
  local header_winid = vim.api.nvim_open_win(header_bufnr, false, header_cfg)
  local bufnr = vim.api.nvim_create_buf(false, true)
  local winid = vim.api.nvim_open_win(bufnr, true, body_cfg)

  vim.bo[header_bufnr].buftype = "nofile"
  vim.bo[header_bufnr].bufhidden = "hide"
  vim.bo[header_bufnr].swapfile = false
  vim.bo[header_bufnr].modifiable = false

  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "markdown"
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(opts.initial_text or "", "\n", { plain = true }))

  local instance = {
    source_bufnr = opts.source_bufnr,
    header_bufnr = header_bufnr,
    header_winid = header_winid,
    bufnr = bufnr,
    winid = winid,
    state = "idle",
    _closing = false,
    _title = opts.title,
    _width = width,
    _height = height,
    _cancel = nil,
  }

  function instance.close(force)
    return do_close(instance, force == true)
  end

  function instance.request_close()
    return do_close(instance, false)
  end

  function instance.set_submitting(status)
    enter_submitting(instance, status)
  end

  function instance.set_idle(status)
    enter_idle(instance, status)
  end

  function instance.set_cancel(cancel)
    instance._cancel = cancel
  end

  function instance.cancel_request()
    if instance.state == "submitting" and instance._cancel then
      instance._cancel()
    end
  end

  function instance.submit()
    if instance.state == "submitting" then
      return
    end

    local text = draft_text(instance)
    if text:match("%S") == nil then
      M._notify("Parley draft is empty", vim.log.levels.WARN)
      return
    end

    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(instance.bufnr) then
        return
      end
      opts.on_submit(instance, text)
    end)
  end

  M._instances[opts.source_bufnr] = instance
  set_header(instance, opts.status)

  vim.keymap.set("n", "q", function()
    instance.request_close()
  end, { buffer = bufnr, silent = true, nowait = true, desc = "Close Parley draft" })
  vim.keymap.set("n", "s", function()
    instance.submit()
  end, { buffer = bufnr, silent = true, nowait = true, desc = "Send Parley draft" })
  vim.keymap.set("n", "C", function()
    instance.cancel_request()
  end, { buffer = bufnr, silent = true, nowait = true, desc = "Cancel Parley request" })
  vim.keymap.set("i", "<C-s>", function()
    instance.submit()
  end, { buffer = bufnr, silent = true, nowait = true, desc = "Submit Parley draft" })

  vim.api.nvim_create_autocmd("WinClosed", {
    buffer = bufnr,
    callback = function()
      if instance._closing then
        return
      end
      vim.schedule(function()
        if instance._closing then
          return
        end
        if instance.state == "submitting" then
          reopen_after_forbidden_close(instance)
          M._notify("Parley request is still running. Press C to cancel it.", vim.log.levels.WARN)
          return
        end
        if is_dirty(instance) and not M._confirm_discard("Are you sure? The draft is not saved and will be lost.") then
          reopen_after_forbidden_close(instance)
          return
        end
        instance.close(true)
      end)
    end,
    desc = "Parley: protect draft window from accidental close",
  })

  vim.cmd.startinsert()
  return instance
end

return M
