--- parley.progress_popup — bottom-right request progress popup.

local progress_state = require("parley.ui_states.progress")
local ui = require("parley.runtime.ui")

local M = {}

local SPINNER_FRAMES = { "-", "\\", "|", "/" }

M._bufnr = nil
M._winid = nil
M._timer = nil
M._spinner_index = 1
M._unsubscribe = nil

---@type fun(): parley.Config|{ progress: parley.ProgressConfig }
M._get_config = function()
  return require("parley").config
end

---@type fun(): uv_timer_t
M._new_timer = function()
  return (vim.uv or vim.loop).new_timer()
end

---@param lines string[]
---@param max_width integer
---@return integer
local function popup_width(lines, max_width)
  local width = 20
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  return math.min(width, max_width)
end

---@param entries parley.ProgressEntry[]
---@return boolean
local function has_running(entries)
  for _, entry in ipairs(entries) do
    if entry.state == "running" then
      return true
    end
  end
  return false
end

---@param entry parley.ProgressEntry
---@return string
local function prefix(entry)
  if entry.state == "running" then
    return SPINNER_FRAMES[M._spinner_index]
  end
  if entry.state == "success" then
    return "+"
  end
  if entry.state == "failed" then
    return "!"
  end
  return "x"
end

---@param entry parley.ProgressEntry
---@return string
local function render_entry(entry)
  return string.format("%s %s  %s", prefix(entry), entry.title, entry.message)
end

---@param lines string[]
---@param cfg parley.ProgressConfig
---@return vim.api.keyset.win_config
local function make_popup_config(lines, cfg)
  return {
    relative = "editor",
    anchor = "SE",
    row = vim.o.lines - vim.o.cmdheight - 1 - cfg.margin_bottom,
    col = vim.o.columns - cfg.margin_right,
    width = popup_width(lines, cfg.max_width),
    height = math.min(#lines, cfg.max_height),
    style = "minimal",
    border = cfg.border,
    focusable = false,
    zindex = 250,
  }
end

local function stop_timer()
  if M._timer then
    M._timer:stop()
    M._timer:close()
    M._timer = nil
  end
end

local function close_popup()
  if M._winid and vim.api.nvim_win_is_valid(M._winid) then
    vim.api.nvim_win_close(M._winid, true)
  end
  M._winid = nil
  if M._bufnr and vim.api.nvim_buf_is_valid(M._bufnr) then
    pcall(vim.api.nvim_buf_delete, M._bufnr, { force = true })
  end
  M._bufnr = nil
end

local function ensure_buffer()
  if M._bufnr and vim.api.nvim_buf_is_valid(M._bufnr) then
    return M._bufnr
  end
  M._bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[M._bufnr].buftype = "nofile"
  vim.bo[M._bufnr].bufhidden = "wipe"
  vim.bo[M._bufnr].swapfile = false
  return M._bufnr
end

local function render()
  ui.assert_main_loop("progress_popup.render")
  local config = M._get_config() or {}
  local popup_cfg = config.progress
    or {
      enabled = true,
      border = "rounded",
      max_width = 60,
      max_height = 8,
      margin_bottom = 1,
      margin_right = 2,
      spinner_interval = 100,
    }
  if popup_cfg.enabled == false then
    stop_timer()
    close_popup()
    return
  end

  local entries = progress_state.list()
  if #entries == 0 then
    stop_timer()
    close_popup()
    return
  end

  if has_running(entries) then
    if not M._timer then
      M._timer = M._new_timer()
      M._timer:start(
        popup_cfg.spinner_interval,
        popup_cfg.spinner_interval,
        vim.schedule_wrap(function()
          M._spinner_index = (M._spinner_index % #SPINNER_FRAMES) + 1
          render()
        end)
      )
    end
  else
    stop_timer()
    M._spinner_index = 1
  end

  local lines = {}
  for _, entry in ipairs(entries) do
    lines[#lines + 1] = render_entry(entry)
  end

  local bufnr = ensure_buffer()
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false

  local win_cfg = make_popup_config(lines, popup_cfg)
  if M._winid and vim.api.nvim_win_is_valid(M._winid) then
    vim.api.nvim_win_set_config(M._winid, win_cfg)
  else
    M._winid = vim.api.nvim_open_win(bufnr, false, win_cfg)
  end
end

function M.setup()
  if M._unsubscribe then
    M._unsubscribe()
    M._unsubscribe = nil
  end
  stop_timer()
  close_popup()
  M._spinner_index = 1
  M._unsubscribe = progress_state.subscribe(function()
    render()
  end)
  local augroup = vim.api.nvim_create_augroup("parley.progress_popup", { clear = true })
  vim.api.nvim_create_autocmd("VimResized", {
    group = augroup,
    callback = function()
      render()
    end,
    desc = "Parley: keep progress popup anchored bottom-right",
  })
  render()
end

function M.teardown()
  if M._unsubscribe then
    M._unsubscribe()
    M._unsubscribe = nil
  end
  stop_timer()
  close_popup()
end

return M
