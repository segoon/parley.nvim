--- parley.hover — cursor-driven discussion previews.
---
--- Two independent, opt-in display modes triggered by the cursor resting on
--- (or leaving) a line with a discussion:
---   • virtual_text.hover  — restrict the signs.lua virt_lines block to the
---     discussion(s) anchored to the current line (CursorMoved, instant).
---   • floating_text.hover — show an unfocused preview float for the
---     discussion(s) anchored to the current line, after the cursor has
---     rested there for `floating_text.hover_delay` seconds (own timer, not
---     Neovim's `updatetime`/CursorHold), closing eagerly on CursorMoved as
---     soon as the cursor leaves the range.

local read_service = require("parley.services.read")
local signs = require("parley.signs")
local render = require("parley.discussion_window.render")

local M = {}

--- @type table<integer, integer> Last cursor line seen per source bufnr.
M._last_line = {}
--- @type table<integer, { winid: integer, bufnr: integer }> Live preview floats per source bufnr.
M._floats = {}
--- @type table<integer, uv.uv_timer_t> Pending hover-open timers per source bufnr.
M._timers = {}

--- @type fun(): parley.Config
M._get_config = function()
  return require("parley").config
end

--- Timer seam; replace in tests to run callbacks synchronously.
--- @type fun(fn: fun(): nil, delay_ms: integer): uv.uv_timer_t
M._defer_fn = function(fn, delay_ms)
  return vim.defer_fn(fn, delay_ms)
end

--- Cancel any pending hover-open timer for `bufnr`.
--- @param bufnr integer
function M._cancel_timer(bufnr)
  local timer = M._timers[bufnr]
  M._timers[bufnr] = nil
  if timer then
    pcall(timer.stop, timer)
    pcall(timer.close, timer)
  end
end

--- Close and clean up the preview float for `bufnr`, if any.
--- @param bufnr integer
function M._close_float(bufnr)
  local float = M._floats[bufnr]
  M._floats[bufnr] = nil
  if not float then
    return
  end
  if vim.api.nvim_win_is_valid(float.winid) then
    vim.api.nvim_win_close(float.winid, true)
  end
  if vim.api.nvim_buf_is_valid(float.bufnr) then
    pcall(vim.api.nvim_buf_delete, float.bufnr, { force = true })
  end
end

--- @param discussions parley.Discussion[]
--- @param mappings table<string, parley.anchor.Mapping>
--- @param bufnr integer
--- @return string[]
local function preview_lines(discussions, mappings, bufnr)
  local lines = render.render_lines(discussions, mappings, {
    format_timestamp = require("parley.discussion_window").format_timestamp,
    reaction_presentation = require("parley.reactions").presentation(bufnr),
  })
  return lines
end

--- Open or update the unfocused preview float for `bufnr`.
--- @param bufnr integer
--- @param discussions parley.Discussion[]
--- @param mappings table<string, parley.anchor.Mapping>
--- @param source_winid integer
--- @param cursor_line integer
local function show_float(bufnr, discussions, mappings, source_winid, cursor_line)
  local config = M._get_config()
  local lines = preview_lines(discussions, mappings, bufnr)
  local window_helpers = require("parley.discussion_window.window")
  local float_cfg = vim.tbl_extend("force", config.floating_text, { focusable = false })
  local win_config = window_helpers.make_win_config(lines, float_cfg, source_winid, cursor_line, nil)

  local float = M._floats[bufnr]
  if float and vim.api.nvim_win_is_valid(float.winid) then
    vim.bo[float.bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(float.bufnr, 0, -1, false, lines)
    vim.bo[float.bufnr].modifiable = false
    vim.api.nvim_win_set_config(float.winid, win_config)
    return
  end

  local bufnr_float = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr_float].buftype = "nofile"
  vim.bo[bufnr_float].bufhidden = "wipe"
  vim.bo[bufnr_float].swapfile = false
  vim.api.nvim_buf_set_lines(bufnr_float, 0, -1, false, lines)
  vim.bo[bufnr_float].filetype = "markdown"
  vim.bo[bufnr_float].modifiable = false

  local winid = vim.api.nvim_open_win(bufnr_float, false, win_config)
  M._floats[bufnr] = { winid = winid, bufnr = bufnr_float }
end

--- @param bufnr integer
--- @return { discussions: parley.Discussion[], mappings: table<string, parley.anchor.Mapping> }|nil
local function get_state(bufnr)
  return read_service.get_buffer_state(bufnr)
end

--- Attempt to open the preview float for `bufnr` at `cursor_line`, provided
--- the cursor is still there when the hover-delay timer fires.
--- @param bufnr integer
--- @param cursor_line integer
function M._on_hover_elapsed(bufnr, cursor_line)
  M._timers[bufnr] = nil

  local config = M._get_config()
  if not config or not config.floating_text.hover then
    return
  end
  if vim.api.nvim_get_current_buf() ~= bufnr then
    return
  end
  local winid = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_cursor(winid)[1] ~= cursor_line then
    return
  end

  local discussion_window = require("parley.discussion_window")
  if discussion_window.is_open(bufnr) then
    return
  end

  local state = get_state(bufnr)
  if not state or not state.discussions then
    return
  end

  local discussions = discussion_window.discussions_for_line(state, cursor_line)
  if #discussions == 0 then
    return
  end

  show_float(bufnr, discussions, state.mappings or {}, winid, cursor_line)
end

--- Start (or restart) the hover-delay timer for `bufnr`/`cursor_line`.
--- @param bufnr integer
--- @param cursor_line integer
--- @param hover_delay number  Seconds to wait before opening the float
function M._schedule_hover(bufnr, cursor_line, hover_delay)
  M._cancel_timer(bufnr)
  local delay_ms = math.max(0, math.floor((hover_delay or 0) * 1000))
  M._timers[bufnr] = M._defer_fn(function()
    M._on_hover_elapsed(bufnr, cursor_line)
  end, delay_ms)
end

--- CursorMoved: instant virtual-text hover filtering, eager float close, and
--- (re)scheduling of the debounced preview-float open.
function M._on_cursor_moved()
  local config = M._get_config()
  if not config then
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  if M._last_line[bufnr] == cursor_line then
    return
  end
  M._last_line[bufnr] = cursor_line

  local state = get_state(bufnr)
  if not state or not state.discussions then
    M._cancel_timer(bufnr)
    return
  end

  if config.virtual_text.enabled and config.virtual_text.hover then
    signs.render(bufnr, state.discussions, state.mappings or {}, {
      signs = config.signs,
      virtual_text = config.virtual_text,
    }, cursor_line)
  end

  if config.floating_text.hover then
    local discussion_window = require("parley.discussion_window")
    local discussions = discussion_window.discussions_for_line(state, cursor_line)
    if #discussions == 0 then
      M._cancel_timer(bufnr)
      M._close_float(bufnr)
    else
      M._schedule_hover(bufnr, cursor_line, config.floating_text.hover_delay)
    end
  end
end

--- Register the hover autocmd. Idempotent no-ops are handled inside the
--- callback by checking the live config, so this only needs to run once.
--- @param augroup integer
function M.setup(augroup)
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = augroup,
    callback = M._on_cursor_moved,
    desc = "Parley: cursor-hover virtual text / preview float tracking",
  })
end

--- Clean up hover state for a buffer being wiped out.
--- @param bufnr integer
function M.close(bufnr)
  M._last_line[bufnr] = nil
  M._cancel_timer(bufnr)
  M._close_float(bufnr)
end

return M
