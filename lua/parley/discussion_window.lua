--- parley.discussion_window — Discussion window for the current line.
---
--- Opens a floating scratch buffer that renders all discussions anchored to the
--- current cursor line. The content is written as Markdown so users with
--- render-markdown.nvim installed get rich rendering automatically.

local read_service = require("parley.services.read")
local composer_ui_state = require("parley.ui_states.composer")
local discussion_ui_state = require("parley.ui_states.discussion")
local timestamp_format = require("parley.timestamp")

local M = {}

local INPUT_HEIGHT = 6
local HIGHLIGHT_NS = vim.api.nvim_create_namespace("parley.discussion_window")
local INPUT_STATUS_NS = vim.api.nvim_create_namespace("parley.discussion_window.input_status")

---@class parley.ComposerHandle
---@field set_submitting fun(status: string): nil
---@field set_idle fun(status: string): nil
---@field set_cancel fun(cancel: fun(): nil): nil
---@field close fun(force?: boolean): boolean

---@class parley.DiscussionWindowInstance
---@field bufnr integer
---@field winid integer
---@field popup any|nil
---@field source_winid integer
---@field comment_ranges table<string, { start_line: integer, end_line: integer }>
---@field input_bufnr integer|nil
---@field input_winid integer|nil
---@field input_state 'hidden'|'idle'|'submitting'
---@field input_cancel fun(): nil
---@field request_close_input fun(): boolean
---@field hide_input fun(force?: boolean): boolean
---@field set_input_status fun(status: string): nil
---@field set_input_submitting fun(status: string): nil
---@field focus_discussion fun(): nil
---@field focus_input fun(): nil
---@field close fun(): nil
---@field submit_input fun(): nil

local REACTION_EMOJI = {
  ["+1"] = "👍",
  ["-1"] = "👎",
  laugh = "😄",
  confused = "😕",
  heart = "❤️",
  hooray = "🎉",
  rocket = "🚀",
  eyes = "👀",
}

local REACTION_CHOICES = {
  { reaction = "+1", emoji = "👍", label = "+1" },
  { reaction = "-1", emoji = "👎", label = "-1" },
  { reaction = "laugh", emoji = "😄", label = "laugh" },
  { reaction = "confused", emoji = "😕", label = "confused" },
  { reaction = "heart", emoji = "❤️", label = "heart" },
  { reaction = "hooray", emoji = "🎉", label = "hooray" },
  { reaction = "rocket", emoji = "🚀", label = "rocket" },
  { reaction = "eyes", emoji = "👀", label = "eyes" },
}

--- Active window instances keyed by source buffer number.
---@type table<integer, parley.DiscussionWindowInstance>
M._instances = {}

local live_instance

--- Notify hook; replace in tests.
--- @type fun(msg: string, level: integer)
M._notify = function(msg, level)
  vim.notify(msg, level)
end

--- Config accessor; replace in tests.
--- @type fun(): parley.Config|{ float: parley.FloatConfig }
M._get_config = function()
  return require("parley").config
end

--- Confirm hook; replace in tests.
--- @type fun(msg: string): boolean
M._confirm_discard = function(msg)
  return vim.fn.confirm(msg, "&Discard\n&Keep editing", 2) == 1
end

--- Current timestamp hook; replace in tests.
--- @type fun(): integer
M._now = function()
  return os.time()
end

--- Date formatting hook; replace in tests.
--- @type fun(fmt: string, time: integer): string
M._date = function(fmt, time)
  return os.date(fmt, time)
end

--- UTC timestamp parsing hook; replace in tests.
--- @type fun(fmt: string, value: string): integer|nil
M._strptime = function(fmt, value)
  return vim.fn.strptime(fmt, value)
end

--- @type fun(epoch: integer): integer
M._utc_offset = function(epoch)
  return timestamp_format.utc_offset(epoch)
end

--- Reaction picker hook; replace in tests.
--- @type fun(items: table[], on_choice: fun(item: table|nil): nil): nil
M._select_reaction = function(items, on_choice)
  require("parley.reaction_picker_window").open(items, {
    prompt = "Add reaction",
    source_winid = vim.api.nvim_get_current_win(),
  }, on_choice)
end

--- @param text string
--- @return string[]
local function split_lines(text)
  if text == "" then
    return { "" }
  end
  return vim.split(text, "\n", { plain = true })
end

--- @param reactions parley.Reaction[]
--- @return string|nil
local function reaction_summary(reactions)
  if #reactions == 0 then
    return nil
  end

  local parts = {}
  for _, reaction in ipairs(reactions) do
    local suffix = reaction.viewer_reacted and " (you)" or ""
    local emoji = REACTION_EMOJI[reaction.type] or reaction.type
    local count = reaction.count > 1 and string.format(" x%d", reaction.count) or ""
    parts[#parts + 1] = string.format("%s%s%s", emoji, count, suffix)
  end
  return table.concat(parts, ", ")
end

---@param comment parley.Comment
---@return table[]
local function reaction_picker_items(comment)
  local by_type = {}
  for _, reaction in ipairs(comment.reactions or {}) do
    by_type[reaction.type] = reaction
  end

  local items = {}
  for _, choice in ipairs(REACTION_CHOICES) do
    local reaction = by_type[choice.reaction]
    items[#items + 1] = vim.tbl_extend("force", choice, {
      count = reaction and reaction.count or 0,
      viewer_reacted = reaction and reaction.viewer_reacted or false,
    })
  end
  return items
end

--- @param timestamp string
--- @return string
local function format_timestamp(timestamp)
  return timestamp_format.format(timestamp, {
    now = M._now,
    date = M._date,
    strptime = M._strptime,
    utc_offset = M._utc_offset,
  })
end

--- @param comment parley.Comment
--- @param by_id table<string, parley.Comment>
--- @param cache table<string, integer>
--- @return integer
local function comment_depth(comment, by_id, cache)
  local cached = cache[comment.id]
  if cached ~= nil then
    return cached
  end

  if not comment.parent_comment_id or not by_id[comment.parent_comment_id] then
    cache[comment.id] = 0
    return 0
  end

  local depth = comment_depth(by_id[comment.parent_comment_id], by_id, cache) + 1
  cache[comment.id] = depth
  return depth
end

--- @param discussion parley.Discussion
--- @param mapping parley.anchor.Mapping|nil
--- @param out string[]
--- @param ranges table<string, { start_line: integer, end_line: integer }>
local function render_discussion(discussion, mapping, out, ranges)
  local status = discussion.resolved and "resolved" or "unresolved"
  local header = status
  if mapping and mapping.stale then
    header = header .. " · stale anchor"
  end
  out[#out + 1] = header
  out[#out + 1] = ""

  if #discussion.comments == 0 then
    out[#out + 1] = "_No comments in this thread._"
    out[#out + 1] = ""
    return
  end

  local by_id = {}
  local depth_cache = {}
  for _, comment in ipairs(discussion.comments) do
    by_id[comment.id] = comment
  end

  for _, comment in ipairs(discussion.comments) do
    local depth = comment_depth(comment, by_id, depth_cache)
    local indent = string.rep("  ", depth)
    local start_line = #out + 1

    out[#out + 1] = string.format("%s- **%s** · %s", indent, comment.author, format_timestamp(comment.created_at))
    for _, line in ipairs(split_lines(comment.body.text)) do
      out[#out + 1] = string.format("%s  %s", indent, line)
    end

    local reactions = reaction_summary(comment.reactions)
    if reactions then
      out[#out + 1] = string.format("%s  ---", indent)
      out[#out + 1] = string.format("%s  %s", indent, reactions)
    end
    ranges[comment.id] = { start_line = start_line, end_line = #out }
    out[#out + 1] = ""
  end
end

--- @param discussions parley.Discussion[]
--- @param mappings table<string, parley.anchor.Mapping>
--- @return string[], table<string, { start_line: integer, end_line: integer }>
local function render_lines(discussions, mappings)
  local out = {}
  local ranges = {}

  local discussion = discussions[1]
  if not discussion then
    return out, ranges
  end

  render_discussion(discussion, mappings[discussion.id], out, ranges)

  while #out > 0 and out[#out] == "" do
    table.remove(out)
  end

  return out, ranges
end

--- @param lines string[]
--- @param max_width integer
--- @return integer
local function window_width(lines, max_width)
  local width = 20
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  return math.min(max_width, width)
end

--- @param lines string[]
--- @param float_cfg parley.FloatConfig
--- @param source_winid integer
--- @param source_line integer
--- @return vim.api.keyset.win_config
local function make_win_config(lines, float_cfg, source_winid, source_line)
  return {
    relative = "win",
    win = source_winid,
    bufpos = { source_line - 1, 0 },
    row = 1,
    col = 0,
    style = "minimal",
    border = float_cfg.border,
    width = window_width(lines, float_cfg.max_width),
    height = math.min(float_cfg.max_height, math.max(1, #lines)),
    focusable = true,
  }
end

--- @param discussion_winid integer
--- @param discussion_height integer
--- @param width integer
--- @param border string
--- @return vim.api.keyset.win_config
local function make_input_win_config(discussion_winid, discussion_height, width, border)
  local pos = vim.api.nvim_win_get_position(discussion_winid)
  return {
    relative = "editor",
    row = pos[1] + discussion_height + 2,
    col = pos[2],
    style = "minimal",
    border = border,
    width = width,
    height = INPUT_HEIGHT,
    focusable = true,
  }
end

--- @param instance table
local function clear_parent_highlight(instance)
  if vim.api.nvim_buf_is_valid(instance.bufnr) then
    vim.api.nvim_buf_clear_namespace(instance.bufnr, HIGHLIGHT_NS, 0, -1)
  end
end

--- @param bufnr integer
--- @param winid integer|nil
--- @return boolean
local function is_source_window(bufnr, winid)
  return winid ~= nil and vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr
end

--- @param bufnr integer
--- @param preferred_winid integer|nil
--- @return integer|nil
local function resolve_source_winid(bufnr, preferred_winid)
  local current_winid = vim.api.nvim_get_current_win()
  if is_source_window(bufnr, current_winid) then
    return current_winid
  end
  if is_source_window(bufnr, preferred_winid) then
    return preferred_winid
  end
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if is_source_window(bufnr, winid) then
      return winid
    end
  end
  return nil
end

--- @param instance table
--- @param comment_id string|nil
local function highlight_parent_comment(instance, comment_id)
  clear_parent_highlight(instance)
  if not comment_id then
    local source_bufnr = instance.source_bufnr or instance.bufnr
    discussion_ui_state.patch(source_bufnr, { highlighted_parent_comment_id = nil })
    return
  end

  local range = instance.comment_ranges[comment_id]
  if not range then
    return
  end

  vim.api.nvim_buf_set_extmark(instance.bufnr, HIGHLIGHT_NS, range.start_line - 1, 0, {
    end_row = range.end_line,
    hl_group = "Visual",
    hl_eol = true,
  })
  local source_bufnr = instance.source_bufnr or instance.bufnr
  discussion_ui_state.patch(source_bufnr, { highlighted_parent_comment_id = comment_id })
end

--- @param instance table
--- @param line integer
--- @return string|nil
local function comment_id_for_line(instance, line)
  local next_comment_id = nil
  local last_comment_id = nil
  for comment_id, range in pairs(instance.comment_ranges) do
    if line >= range.start_line and line <= range.end_line then
      return comment_id
    end
    if range.start_line > line then
      if next_comment_id == nil or range.start_line < instance.comment_ranges[next_comment_id].start_line then
        next_comment_id = comment_id
      end
    elseif last_comment_id == nil or range.end_line > instance.comment_ranges[last_comment_id].end_line then
      last_comment_id = comment_id
    end
  end
  return next_comment_id or last_comment_id
end

--- @param source_bufnr integer
--- @return parley.Discussion|nil, parley.Comment|nil, integer|nil
local function current_selection(source_bufnr)
  local instance = live_instance(source_bufnr)
  local discussion = M.current_discussion(source_bufnr)
  if not instance or not discussion then
    return discussion, nil, nil
  end

  local cursor = vim.api.nvim_win_get_cursor(instance.winid)
  local comment_id = comment_id_for_line(instance, cursor[1])
  if not comment_id then
    return discussion, nil, cursor[1]
  end

  for _, comment in ipairs(discussion.comments) do
    if comment.id == comment_id then
      return discussion, comment, cursor[1]
    end
  end
  return discussion, nil, cursor[1]
end

--- @param source_bufnr integer
local function sync_selected_comment(source_bufnr)
  local instance = live_instance(source_bufnr)
  local discussion, comment = current_selection(source_bufnr)
  if not instance then
    return
  end

  clear_parent_highlight(instance)
  if not discussion or not comment then
    discussion_ui_state.patch(source_bufnr, { selected_comment_id = nil })
    return
  end

  local range = instance.comment_ranges[comment.id]
  if range then
    vim.api.nvim_buf_set_extmark(instance.bufnr, HIGHLIGHT_NS, range.start_line - 1, 0, {
      end_row = range.end_line,
      hl_group = "Visual",
      hl_eol = true,
    })
  end
  discussion_ui_state.patch(source_bufnr, { selected_comment_id = comment.id })
end

--- @param instance table
local function focus_discussion(instance)
  if vim.api.nvim_win_is_valid(instance.winid) then
    vim.api.nvim_set_current_win(instance.winid)
  end
end

--- @param instance table
local function focus_input(instance)
  if instance.input_winid and vim.api.nvim_win_is_valid(instance.input_winid) then
    vim.api.nvim_set_current_win(instance.input_winid)
  end
end

---@param instance parley.DiscussionWindowInstance
local function clear_input_status_overlay(instance)
  if instance.input_bufnr and vim.api.nvim_buf_is_valid(instance.input_bufnr) then
    vim.api.nvim_buf_clear_namespace(instance.input_bufnr, INPUT_STATUS_NS, 0, -1)
  end
end

---@param instance parley.DiscussionWindowInstance
---@param status string
local function set_input_status_overlay(instance, status)
  if not instance.input_bufnr or not vim.api.nvim_buf_is_valid(instance.input_bufnr) then
    return
  end
  clear_input_status_overlay(instance)
  vim.api.nvim_buf_set_extmark(instance.input_bufnr, INPUT_STATUS_NS, 0, 0, {
    virt_lines = { { { status, "Comment" } } },
    virt_lines_above = true,
  })
end

--- @param instance table
--- @param force boolean
--- @return boolean
local function hide_input(instance, force)
  if instance.input_state == "hidden" then
    return true
  end

  if not force then
    if instance.input_state == "submitting" then
      M._notify("Parley request in progress. Press C to cancel the request.", vim.log.levels.WARN)
      return false
    end

    local text = table.concat(vim.api.nvim_buf_get_lines(instance.input_bufnr, 0, -1, false), "\n")
    if text:match("%S") and not M._confirm_discard("Are you sure? The draft is not saved and will be lost.") then
      return false
    end
  end

  clear_parent_highlight(instance)
  instance.input_state = "hidden"
  instance.input_cancel = nil
  local source_bufnr = instance.source_bufnr or instance.bufnr
  composer_ui_state.clear(source_bufnr)
  discussion_ui_state.patch(source_bufnr, { input_visible = false, highlighted_parent_comment_id = nil })
  if instance.input_winid and vim.api.nvim_win_is_valid(instance.input_winid) then
    vim.api.nvim_win_close(instance.input_winid, true)
  end
  instance.input_winid = nil
  if instance.input_bufnr and vim.api.nvim_buf_is_valid(instance.input_bufnr) then
    clear_input_status_overlay(instance)
    vim.bo[instance.input_bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(instance.input_bufnr, 0, -1, false, {})
  end
  focus_discussion(instance)
  sync_selected_comment(source_bufnr)
  return true
end

--- @param instance table
--- @param status string
local function set_input_status(instance, status)
  if not instance.input_bufnr or not vim.api.nvim_buf_is_valid(instance.input_bufnr) then
    return
  end
  set_input_status_overlay(instance, status)
  vim.bo[instance.input_bufnr].modifiable = true
end

--- @param instance table
--- @param status string
local function set_input_submitting(instance, status)
  instance.input_state = "submitting"
  if instance.input_bufnr and vim.api.nvim_buf_is_valid(instance.input_bufnr) then
    set_input_status_overlay(instance, status)
    vim.bo[instance.input_bufnr].modifiable = false
  end
end

--- @param instance table
local function setup_input_keymaps(instance)
  vim.keymap.set("n", "q", function()
    instance.request_close_input()
  end, { buffer = instance.input_bufnr, silent = true, nowait = true, desc = "Close Parley draft" })
  vim.keymap.set("n", "s", function()
    instance.submit_input()
  end, { buffer = instance.input_bufnr, silent = true, nowait = true, desc = "Send Parley draft" })
  vim.keymap.set("n", "C", function()
    if instance.input_state == "submitting" and instance.input_cancel then
      instance.input_cancel()
    end
  end, { buffer = instance.input_bufnr, silent = true, nowait = true, desc = "Cancel Parley request" })
  vim.keymap.set("i", "<C-s>", function()
    instance.submit_input()
  end, { buffer = instance.input_bufnr, silent = true, nowait = true, desc = "Submit Parley draft" })
  vim.api.nvim_create_autocmd("WinClosed", {
    buffer = instance.input_bufnr,
    callback = function()
      vim.schedule(function()
        if instance.input_state ~= "hidden" and not instance._closing then
          instance.request_close_input()
        end
      end)
    end,
    desc = "Parley: protect embedded draft window",
  })
end

--- @param src_bufnr integer
--- @param instance parley.DiscussionWindowInstance
local function setup_discussion_autocmds(src_bufnr, instance)
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = instance.bufnr,
    callback = function()
      sync_selected_comment(src_bufnr)
    end,
    desc = "Parley: highlight selected discussion comment",
  })
end

---@param src_bufnr integer
---@param instance parley.DiscussionWindowInstance
---@param status string
---@param initial_text string|nil
---@param parent_comment_id string|nil
---@param composer parley.ComposerHandle
---@param on_submit fun(composer: parley.ComposerHandle, text: string): boolean|nil
local function show_input(src_bufnr, instance, status, initial_text, parent_comment_id, composer, on_submit)
  local discussion_cfg = vim.api.nvim_win_get_config(instance.winid)
  local discussion_height = discussion_cfg.height or vim.api.nvim_win_get_height(instance.winid)
  local width = discussion_cfg.width or vim.api.nvim_win_get_width(instance.winid)

  if not instance.input_bufnr or not vim.api.nvim_buf_is_valid(instance.input_bufnr) then
    instance.input_bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[instance.input_bufnr].buftype = "nofile"
    vim.bo[instance.input_bufnr].bufhidden = "hide"
    vim.bo[instance.input_bufnr].swapfile = false
    vim.bo[instance.input_bufnr].filetype = "markdown"
    setup_input_keymaps(instance)
  end

  local input_cfg = make_input_win_config(instance.winid, discussion_height, width, discussion_cfg.border or "rounded")
  if instance.input_winid and vim.api.nvim_win_is_valid(instance.input_winid) then
    vim.api.nvim_win_set_config(instance.input_winid, input_cfg)
  else
    instance.input_winid = vim.api.nvim_open_win(instance.input_bufnr, true, input_cfg)
  end

  instance.input_state = "idle"
  instance.input_cancel = nil
  discussion_ui_state.patch(src_bufnr, { input_visible = true })
  instance.submit_input = function()
    if instance.input_state == "submitting" then
      return
    end

    local text = table.concat(vim.api.nvim_buf_get_lines(instance.input_bufnr, 0, -1, false), "\n")
    if text:match("%S") == nil then
      M._notify("Parley draft is empty", vim.log.levels.WARN)
      return
    end

    vim.schedule(function()
      if instance.input_state ~= "hidden" then
        on_submit(composer, text)
      end
    end)
  end

  instance.request_close_input = function()
    return hide_input(instance, false)
  end
  instance.hide_input = function(force)
    return hide_input(instance, force == true)
  end
  instance.set_input_status = function(new_status)
    instance.input_state = "idle"
    set_input_status(instance, new_status)
    focus_input(instance)
  end
  instance.set_input_submitting = function(new_status)
    set_input_submitting(instance, new_status)
  end
  instance.focus_discussion = function()
    focus_discussion(instance)
  end
  instance.focus_input = function()
    focus_input(instance)
  end

  local body_lines = vim.split(initial_text or "", "\n", { plain = true })
  if #body_lines == 0 then
    body_lines = { "" }
  end
  vim.bo[instance.input_bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(instance.input_bufnr, 0, -1, false, body_lines)
  vim.bo[instance.input_bufnr].modifiable = true
  set_input_status_overlay(instance, status)
  composer_ui_state.patch(src_bufnr, { draft = initial_text or "", visible = true, submit_state = "idle" })
  highlight_parent_comment(instance, parent_comment_id)
  focus_input(instance)
  if instance.input_winid and vim.api.nvim_win_is_valid(instance.input_winid) then
    vim.api.nvim_win_set_cursor(instance.input_winid, { 1, 0 })
  end
  vim.cmd.startinsert()
end

---@param instance parley.DiscussionWindowInstance
---@return parley.ComposerHandle
local function composer_adapter(instance)
  return {
    set_submitting = function(status)
      instance.set_input_submitting(status)
    end,
    set_idle = function(status)
      instance.set_input_status(status)
    end,
    set_cancel = function(cancel)
      instance.input_cancel = cancel
    end,
    close = function(force)
      return hide_input(instance, force == true)
    end,
  }
end

---@param lines string[]
---@param float_cfg parley.FloatConfig
---@param source_winid integer
---@param source_line integer
---@return parley.DiscussionWindowInstance
local function create_instance(lines, float_cfg, source_winid, source_line)
  local config = make_win_config(lines, float_cfg, source_winid, source_line)
  local bufnr = vim.api.nvim_create_buf(false, true)
  local winid = vim.api.nvim_open_win(bufnr, true, config)
  local closed = false
  local instance = {}
  instance = {
    bufnr = bufnr,
    winid = winid,
    popup = nil,
    source_bufnr = nil,
    source_winid = source_winid,
    comment_ranges = {},
    input_bufnr = nil,
    input_winid = nil,
    input_state = "hidden",
    input_cancel = nil,
    request_close_input = function()
      return true
    end,
    hide_input = function()
      return true
    end,
    set_input_status = function() end,
    set_input_submitting = function() end,
    focus_discussion = function() end,
    focus_input = function() end,
    close = function()
      if closed then
        return
      end
      closed = true
      instance._closing = true
      hide_input(instance, true)
      if vim.api.nvim_win_is_valid(winid) then
        vim.api.nvim_win_close(winid, true)
      end
      if vim.api.nvim_buf_is_valid(bufnr) then
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      end
      if instance.input_bufnr and vim.api.nvim_buf_is_valid(instance.input_bufnr) then
        pcall(vim.api.nvim_buf_delete, instance.input_bufnr, { force = true })
      end
    end,
  }
  instance.focus_discussion = function()
    focus_discussion(instance)
  end
  instance.focus_input = function()
    focus_input(instance)
  end
  return instance
end

--- @param bufnr integer
--- @return table|nil
live_instance = function(bufnr)
  local instance = M._instances[bufnr]
  if not instance then
    return nil
  end
  if not vim.api.nvim_buf_is_valid(instance.bufnr) or not vim.api.nvim_win_is_valid(instance.winid) then
    M._instances[bufnr] = nil
    return nil
  end
  return instance
end

--- @param bufnr integer
--- @return integer
local function resolve_source_bufnr(bufnr)
  if M._instances[bufnr] ~= nil then
    return bufnr
  end

  for source_bufnr, instance in pairs(M._instances) do
    if instance.bufnr == bufnr or instance.input_bufnr == bufnr then
      return source_bufnr
    end
  end

  return bufnr
end

M.resolve_source_bufnr = resolve_source_bufnr

--- @param src_bufnr integer
--- @param instance table
--- @param lines string[]
local function write_lines(src_bufnr, instance, lines)
  vim.bo[instance.bufnr].buftype = "nofile"
  vim.bo[instance.bufnr].bufhidden = "wipe"
  vim.bo[instance.bufnr].swapfile = false
  vim.bo[instance.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(instance.bufnr, 0, -1, false, lines)
  vim.bo[instance.bufnr].filetype = "markdown"
  vim.bo[instance.bufnr].modifiable = false

  vim.wo[instance.winid].wrap = true
  vim.wo[instance.winid].winfixbuf = true

  vim.keymap.set("n", "q", function()
    M.close(src_bufnr)
  end, { buffer = instance.bufnr, silent = true, nowait = true, desc = "Close Parley discussion" })

  vim.keymap.set("n", "r", function()
    M.reply_current_line(src_bufnr)
  end, { buffer = instance.bufnr, silent = true, nowait = true, desc = "Reply in Parley discussion" })
  vim.keymap.set("n", "R", function()
    M.react_current_comment(src_bufnr)
  end, { buffer = instance.bufnr, silent = true, nowait = true, desc = "React to Parley comment" })
  vim.keymap.set("n", "e", function()
    M.edit_current_comment(src_bufnr)
  end, { buffer = instance.bufnr, silent = true, nowait = true, desc = "Edit Parley comment" })
  vim.keymap.set("n", "d", function()
    M.delete_current_comment(src_bufnr)
  end, { buffer = instance.bufnr, silent = true, nowait = true, desc = "Delete Parley comment" })
end

--- @param bufnr integer
--- @param lines string[]
--- @param float_cfg parley.FloatConfig
--- @param source_winid integer
--- @param source_line integer
--- @return table
local function ensure_instance(bufnr, lines, float_cfg, source_winid, source_line)
  local instance = live_instance(bufnr)
  if instance then
    instance.source_bufnr = bufnr
    instance.source_winid = source_winid
    vim.api.nvim_win_set_config(instance.winid, make_win_config(lines, float_cfg, source_winid, source_line))
    if instance.input_winid and vim.api.nvim_win_is_valid(instance.input_winid) then
      local discussion_cfg = vim.api.nvim_win_get_config(instance.winid)
      vim.api.nvim_win_set_config(
        instance.input_winid,
        make_input_win_config(
          instance.winid,
          discussion_cfg.height or #lines,
          discussion_cfg.width or 20,
          discussion_cfg.border
        )
      )
    end
    return instance
  end

  instance = create_instance(lines, float_cfg, source_winid, source_line)
  instance.source_bufnr = bufnr
  M._instances[bufnr] = instance
  setup_discussion_autocmds(bufnr, instance)
  return instance
end

--- @param state { discussions: parley.Discussion[], mappings: table<string, parley.anchor.Mapping> }
--- @param cursor_line integer
--- @return parley.Discussion[]
local function discussions_for_line(state, cursor_line)
  for _, discussion in ipairs(state.discussions) do
    local mapping = state.mappings[discussion.id]
    if mapping and mapping.local_line == cursor_line then
      return { discussion }
    end
  end
  return {}
end

--- @param state { discussions: parley.Discussion[] }
--- @param discussion_id string
--- @return parley.Discussion|nil
local function discussion_by_id(state, discussion_id)
  for _, discussion in ipairs(state.discussions) do
    if discussion.id == discussion_id then
      return discussion
    end
  end
  return nil
end

--- @param bufnr integer
--- @param discussions parley.Discussion[]
--- @param mappings table<string, parley.anchor.Mapping>
--- @param source_winid integer
--- @param source_line integer
--- @return boolean
local function open_discussions(bufnr, discussions, mappings, source_winid, source_line)
  local config = M._get_config() or {}
  local float_cfg = config.float or {
    border = "rounded",
    max_width = 80,
    max_height = 30,
  }
  local lines, comment_ranges = render_lines(discussions, mappings)
  local instance = ensure_instance(bufnr, lines, float_cfg, source_winid, source_line)
  instance.comment_ranges = comment_ranges
  write_lines(bufnr, instance, lines)
  clear_parent_highlight(instance)
  discussion_ui_state.set(bufnr, {
    visible = true,
    current_discussion_id = discussions[1].id,
    current_source_line = source_line,
    highlighted_parent_comment_id = nil,
    selected_comment_id = nil,
    input_visible = instance.input_state ~= "hidden",
  })
  sync_selected_comment(bufnr)
  return true
end

--- Return whether the discussion window is open for `bufnr`.
--- @param bufnr integer
--- @return boolean
function M.is_open(bufnr)
  return live_instance(resolve_source_bufnr(bufnr)) ~= nil
end

--- Close the discussion window for `bufnr`.
--- @param bufnr integer
--- @return boolean  true when a window was closed
function M.close(bufnr)
  bufnr = resolve_source_bufnr(bufnr)

  local instance = live_instance(bufnr)
  if not instance then
    M._instances[bufnr] = nil
    discussion_ui_state.clear(bufnr)
    composer_ui_state.clear(bufnr)
    return false
  end

  M._instances[bufnr] = nil
  discussion_ui_state.clear(bufnr)
  composer_ui_state.clear(bufnr)
  instance.close()
  return true
end

--- Open the discussion window for the current line in `bufnr`.
--- @param bufnr integer
--- @param opts? { cursor_line?: integer }
--- @return boolean  true when a window was opened or updated
function M.open_current_line(bufnr, opts)
  opts = opts or {}
  local state = read_service.get_buffer_state(bufnr)
  local source_winid = resolve_source_winid(bufnr, live_instance(bufnr) and live_instance(bufnr).source_winid or nil)
  local cursor_line = opts.cursor_line
    or (source_winid and vim.api.nvim_win_get_cursor(source_winid)[1])
    or vim.api.nvim_win_get_cursor(0)[1]

  if not state then
    M.close(bufnr)
    M._notify("No Parley discussions on this line", vim.log.levels.INFO)
    return false
  end

  if not source_winid then
    M.close(bufnr)
    M._notify("Open the source buffer to view Parley discussions", vim.log.levels.INFO)
    return false
  end

  local discussions = discussions_for_line(state, cursor_line)
  if #discussions == 0 then
    M.close(bufnr)
    M._notify("No Parley discussions on this line", vim.log.levels.INFO)
    return false
  end

  return open_discussions(bufnr, discussions, state.mappings or {}, source_winid, cursor_line)
end

--- Open a specific discussion for `bufnr`.
--- @param bufnr integer
--- @param discussion_id string
--- @return boolean
function M.open_discussion(bufnr, discussion_id)
  bufnr = resolve_source_bufnr(bufnr)
  local state = read_service.get_buffer_state(bufnr)
  local source_winid = resolve_source_winid(bufnr, live_instance(bufnr) and live_instance(bufnr).source_winid or nil)

  if not state then
    M.close(bufnr)
    M._notify("No Parley discussions in this buffer", vim.log.levels.INFO)
    return false
  end

  if not source_winid then
    M.close(bufnr)
    M._notify("Open the source buffer to view Parley discussions", vim.log.levels.INFO)
    return false
  end

  local discussion = discussion_by_id(state, discussion_id)
  if not discussion then
    M.close(bufnr)
    M._notify("Parley discussion not found", vim.log.levels.INFO)
    return false
  end

  local mapping = state.mappings and state.mappings[discussion.id] or nil
  local source_line = (mapping and mapping.local_line) or discussion.line
  return open_discussions(bufnr, { discussion }, state.mappings or {}, source_winid, source_line)
end

--- Return the first discussion for the current source buffer line.
--- @param bufnr integer
--- @return parley.Discussion|nil
function M.current_discussion(bufnr)
  bufnr = resolve_source_bufnr(bufnr)
  local ui_state = discussion_ui_state.get(bufnr)
  local snapshot = read_service.get_buffer_state(bufnr)
  local discussion_id = ui_state and ui_state.current_discussion_id or nil
  if snapshot and discussion_id then
    for _, discussion in ipairs(snapshot.discussions or {}) do
      if discussion.id == discussion_id then
        return discussion
      end
    end
  end
  return nil
end

--- Return the currently selected comment for the discussion float.
--- @param bufnr integer
--- @return parley.Comment|nil
function M.current_comment(bufnr)
  bufnr = resolve_source_bufnr(bufnr)
  local _, comment = current_selection(bufnr)
  return comment
end

--- Open the reply input for the first discussion on the current line.
--- @param bufnr integer
--- @return boolean
function M.reply_current_line(bufnr)
  bufnr = resolve_source_bufnr(bufnr)
  local discussion = M.current_discussion(bufnr)
  if not discussion then
    M._notify("Open a Parley discussion before replying", vim.log.levels.INFO)
    return false
  end

  local parent = discussion.comments[#discussion.comments]
  if not parent then
    M._notify("Cannot reply to an empty Parley discussion", vim.log.levels.WARN)
    return false
  end

  require("parley.services.write").open_reply_input(bufnr, discussion.id, parent.id)
  return true
end

--- React to the currently selected comment.
--- @param bufnr integer
--- @return boolean
function M.react_current_comment(bufnr)
  bufnr = resolve_source_bufnr(bufnr)
  local ui_state = discussion_ui_state.get(bufnr)
  local discussion, comment = current_selection(bufnr)
  if not discussion or not comment then
    M._notify("Open a Parley discussion before reacting", vim.log.levels.INFO)
    return false
  end

  M._select_reaction(reaction_picker_items(comment), function(item)
    if not item then
      return
    end
    require("parley.services.write").react_comment(
      bufnr,
      ui_state and ui_state.current_source_line or nil,
      comment.id,
      item.reaction
    )
  end)
  return true
end

--- Edit the currently selected comment.
--- @param bufnr integer
--- @return boolean
function M.edit_current_comment(bufnr)
  bufnr = resolve_source_bufnr(bufnr)
  local discussion, comment = current_selection(bufnr)
  if not discussion or not comment then
    M._notify("Open a Parley discussion before editing", vim.log.levels.INFO)
    return false
  end
  if not comment.is_own then
    M._notify("You can only edit your own Parley comments", vim.log.levels.WARN)
    return false
  end

  require("parley.services.write").open_edit_input(bufnr, discussion.id, comment.id, comment.body.text)
  return true
end

--- Delete the currently selected comment.
--- @param bufnr integer
--- @return boolean
function M.delete_current_comment(bufnr)
  bufnr = resolve_source_bufnr(bufnr)
  local ui_state = discussion_ui_state.get(bufnr)
  local discussion, comment = current_selection(bufnr)
  if not discussion or not comment then
    M._notify("Open a Parley discussion before deleting", vim.log.levels.INFO)
    return false
  end
  if not comment.is_own then
    M._notify("You can only delete your own Parley comments", vim.log.levels.WARN)
    return false
  end

  local ok =
    require("parley.services.write").delete_comment(bufnr, ui_state and ui_state.current_source_line or nil, comment.id)
  if ok == false then
    return false
  end
  return true
end

--- Show the embedded input pane for a reply.
--- @param bufnr integer
--- @param opts {
---   parent_comment_id: string,
---   status: string,
---   on_submit: fun(composer: parley.ComposerHandle, text: string): boolean|nil,
---   initial_text?: string,
--- }
--- @return parley.ComposerHandle|nil
function M.show_reply_input(bufnr, opts)
  bufnr = resolve_source_bufnr(bufnr)
  local instance = live_instance(bufnr)
  if not instance or not M.current_discussion(bufnr) then
    M._notify("Open a Parley discussion before replying", vim.log.levels.INFO)
    return nil
  end

  local composer = composer_adapter(instance)
  show_input(bufnr, instance, opts.status, opts.initial_text, opts.parent_comment_id, composer, opts.on_submit)
  return composer
end

--- Show the embedded input pane for a new comment.
--- @param bufnr integer
--- @param opts {
---   cursor_line: integer,
---   status: string,
---   on_submit: fun(composer: parley.ComposerHandle, text: string): boolean|nil,
---   initial_text?: string,
--- }
--- @return parley.ComposerHandle|nil
function M.show_new_comment_input(bufnr, opts)
  bufnr = resolve_source_bufnr(bufnr)
  local instance = live_instance(bufnr)
  if not instance then
    local state = read_service.get_buffer_state(bufnr)
    local config = M._get_config() or {}
    local source_winid = resolve_source_winid(bufnr, nil)
    local float_cfg = config.float or {
      border = "rounded",
      max_width = 80,
      max_height = 30,
    }
    if not source_winid then
      M._notify("Open the source buffer to write a Parley comment", vim.log.levels.INFO)
      return nil
    end
    local discussions = state and discussions_for_line(state, opts.cursor_line) or {}
    if #discussions > 0 then
      local lines, comment_ranges = render_lines(discussions, state.mappings)
      instance = ensure_instance(bufnr, lines, float_cfg, source_winid, opts.cursor_line)
      instance.comment_ranges = comment_ranges
      write_lines(bufnr, instance, lines)
      discussion_ui_state.set(bufnr, {
        visible = true,
        current_discussion_id = discussions[1].id,
        current_source_line = opts.cursor_line,
        highlighted_parent_comment_id = nil,
        selected_comment_id = nil,
        input_visible = false,
      })
    else
      local placeholder = { "_No discussion on this line yet._" }
      instance = ensure_instance(bufnr, placeholder, float_cfg, source_winid, opts.cursor_line)
      instance.comment_ranges = {}
      write_lines(bufnr, instance, placeholder)
      discussion_ui_state.set(bufnr, {
        visible = true,
        current_discussion_id = nil,
        current_source_line = opts.cursor_line,
        highlighted_parent_comment_id = nil,
        selected_comment_id = nil,
        input_visible = false,
      })
    end
  end

  local composer = composer_adapter(instance)
  show_input(bufnr, instance, opts.status, opts.initial_text, nil, composer, opts.on_submit)
  return composer
end

--- Toggle the discussion window for `bufnr`.
--- @param bufnr integer
--- @return boolean  true when a window ends up open
function M.toggle_current_line(bufnr)
  bufnr = resolve_source_bufnr(bufnr)

  if M.is_open(bufnr) then
    M.close(bufnr)
    return false
  end
  return M.open_current_line(bufnr)
end

return M
