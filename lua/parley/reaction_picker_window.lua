--- parley.reaction_picker_window — visual reaction picker popup.

local M = {}

M._bufnr = nil
M._winid = nil
M._items = nil
M._index = nil
M._on_choice = nil
M._source_winid = nil

---@type fun(): parley.Config|{ float: parley.FloatConfig }
M._get_config = function()
  return require("parley").config
end

---@param item table
---@return string
local function default_render_item(item)
  local text = string.format("%s %s", item.emoji or "", item.label or item.reaction or "")
  if item.count and item.count > 1 then
    text = string.format("%s x%d", text, item.count)
  end
  if item.viewer_reacted then
    text = text .. " (you)"
  end
  return vim.trim(text)
end

---@param lines string[]
---@param source_winid integer|nil
---@param prompt string|nil
---@return vim.api.keyset.win_config
local function make_config(lines, source_winid, prompt)
  local config = M._get_config() or {}
  local float_cfg = config.float or {
    border = "rounded",
    max_width = 80,
    max_height = 30,
  }
  local width = 20
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  if prompt and prompt ~= "" then
    width = math.max(width, vim.fn.strdisplaywidth(prompt) + 2)
  end

  width = math.min(width, float_cfg.max_width)
  local height = math.min(#lines, float_cfg.max_height)

  if source_winid and vim.api.nvim_win_is_valid(source_winid) then
    local win_width = vim.api.nvim_win_get_width(source_winid)
    local win_height = vim.api.nvim_win_get_height(source_winid)
    width = math.min(width, math.max(12, win_width - 4))
    height = math.min(height, math.max(1, win_height - 2))
    return {
      relative = "win",
      win = source_winid,
      row = math.max(0, math.floor((win_height - height) / 2)),
      col = math.max(0, math.floor((win_width - width) / 2)),
      width = width,
      height = height,
      style = "minimal",
      border = float_cfg.border,
      focusable = true,
      zindex = 260,
      title = prompt and (" " .. prompt .. " ") or nil,
      title_pos = "center",
    }
  end

  width = math.min(width, math.max(12, vim.o.columns - 4))
  height = math.min(height, math.max(1, vim.o.lines - vim.o.cmdheight - 4))
  return {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - vim.o.cmdheight - height) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = float_cfg.border,
    focusable = true,
    zindex = 260,
    title = prompt and (" " .. prompt .. " ") or nil,
    title_pos = "center",
  }
end

---@return boolean
function M.is_open()
  if not M._bufnr or not M._winid then
    return false
  end
  if not vim.api.nvim_buf_is_valid(M._bufnr) or not vim.api.nvim_win_is_valid(M._winid) then
    M._bufnr = nil
    M._winid = nil
    M._items = nil
    M._index = nil
    M._on_choice = nil
    M._source_winid = nil
    return false
  end
  return true
end

local function teardown()
  local bufnr = M._bufnr
  local winid = M._winid
  M._bufnr = nil
  M._winid = nil
  M._items = nil
  M._index = nil
  M._on_choice = nil
  M._source_winid = nil
  if winid and vim.api.nvim_win_is_valid(winid) then
    vim.api.nvim_win_close(winid, true)
  end
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
end

---@param choice table|nil
local function finish(choice)
  local on_choice = M._on_choice
  local source_winid = M._source_winid
  teardown()
  if source_winid and vim.api.nvim_win_is_valid(source_winid) then
    vim.api.nvim_set_current_win(source_winid)
  end
  if on_choice then
    on_choice(choice)
  end
end

---@return table|nil
function M.current_item()
  if not M.is_open() then
    return nil
  end
  return M._items[M._index]
end

---@param index integer
local function set_index(index)
  if not M.is_open() or not M._items or #M._items == 0 then
    return
  end
  M._index = math.max(1, math.min(index, #M._items))
  vim.api.nvim_win_set_cursor(M._winid, { M._index, 0 })
end

---@param delta integer
function M.move(delta)
  if not M.is_open() then
    return
  end
  set_index((M._index or 1) + delta)
end

function M.confirm()
  local item = M.current_item()
  finish(item)
end

function M.cancel()
  finish(nil)
end

function M.close()
  teardown()
end

---@param bufnr integer
local function setup_keymaps(bufnr)
  vim.keymap.set("n", "q", function()
    M.cancel()
  end, { buffer = bufnr, silent = true, nowait = true, desc = "Close Parley reaction picker" })
  vim.keymap.set("n", "<Esc>", function()
    M.cancel()
  end, { buffer = bufnr, silent = true, nowait = true, desc = "Cancel Parley reaction picker" })
  vim.keymap.set("n", "<CR>", function()
    M.confirm()
  end, { buffer = bufnr, silent = true, nowait = true, desc = "Confirm Parley reaction picker" })
  vim.keymap.set("n", "j", function()
    M.move(1)
  end, { buffer = bufnr, silent = true, nowait = true, desc = "Next Parley reaction" })
  vim.keymap.set("n", "k", function()
    M.move(-1)
  end, { buffer = bufnr, silent = true, nowait = true, desc = "Previous Parley reaction" })
  vim.keymap.set("n", "<Down>", function()
    M.move(1)
  end, { buffer = bufnr, silent = true, nowait = true, desc = "Next Parley reaction" })
  vim.keymap.set("n", "<Up>", function()
    M.move(-1)
  end, { buffer = bufnr, silent = true, nowait = true, desc = "Previous Parley reaction" })
end

---@param bufnr integer
local function setup_autocmds(bufnr)
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = bufnr,
    callback = function()
      if not M.is_open() then
        return
      end
      local cursor = vim.api.nvim_win_get_cursor(M._winid)
      M._index = math.max(1, math.min(cursor[1], #M._items))
    end,
    desc = "Parley: track reaction picker selection",
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(M._winid),
    callback = function()
      vim.schedule(function()
        if M._bufnr == bufnr then
          M.cancel()
        end
      end)
    end,
    desc = "Parley: close reaction picker state",
  })
end

---@param items table[]
---@param opts? { prompt?: string, source_winid?: integer, render_item?: fun(item: table): string }
---@param on_choice fun(item: table|nil): nil
---@return boolean
function M.open(items, opts, on_choice)
  opts = opts or {}
  if #items == 0 then
    on_choice(nil)
    return false
  end

  M.close()

  local render = opts.render_item or default_render_item
  local lines = {}
  for _, item in ipairs(items) do
    lines[#lines + 1] = render(item)
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false

  local winid = vim.api.nvim_open_win(bufnr, true, make_config(lines, opts.source_winid, opts.prompt))
  vim.wo[winid].cursorline = true
  vim.wo[winid].wrap = false
  vim.wo[winid].winfixbuf = true

  M._bufnr = bufnr
  M._winid = winid
  M._items = vim.deepcopy(items)
  M._index = 1
  M._on_choice = on_choice
  M._source_winid = opts.source_winid

  setup_keymaps(bufnr)
  setup_autocmds(bufnr)
  set_index(1)
  return true
end

return M
