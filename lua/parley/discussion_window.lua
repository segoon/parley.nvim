--- parley.discussion_window — Discussion window for the current line.
---
--- Opens a floating scratch buffer that renders all discussions anchored to the
--- current cursor line. The content is written as Markdown so users with
--- render-markdown.nvim installed get rich rendering automatically.

local read_service = require("parley.services.read")
local composer_ui_state = require("parley.ui_states.composer")
local discussion_ui_state = require("parley.ui_states.discussion")
local timestamp_format = require("parley.timestamp")
local render = require("parley.discussion_window.render")
local input = require("parley.discussion_window.input")
local selection = require("parley.discussion_window.selection")
local window_helpers = require("parley.discussion_window.window")

local dbg = require("parley.debug")

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

---@param timestamp string
---@return string
local function format_timestamp(timestamp)
  return timestamp_format.format(timestamp, {
    now = M._now,
    date = M._date,
    strptime = M._strptime,
    utc_offset = M._utc_offset,
  })
end

---@param bufnr integer
---@return table|nil
live_instance = function(bufnr)
  return window_helpers.live_instance(M._instances, bufnr)
end

local selection_controller = selection.new({
  highlight_ns = HIGHLIGHT_NS,
  discussion_ui_state = discussion_ui_state,
  live_instance = live_instance,
  current_discussion = function(bufnr)
    return M.current_discussion(bufnr)
  end,
})

local clear_parent_highlight = selection_controller.clear_parent_highlight
local highlight_parent_comment = selection_controller.highlight_parent_comment
local current_selection = selection_controller.current_selection
local sync_selected_comment = selection_controller.sync_selected_comment

local input_controller = input.new({
  notify = function(msg, level)
    M._notify(msg, level)
  end,
  confirm_discard = function(msg)
    return M._confirm_discard(msg)
  end,
  composer_ui_state = composer_ui_state,
  discussion_ui_state = discussion_ui_state,
  input_status_ns = INPUT_STATUS_NS,
  clear_parent_highlight = clear_parent_highlight,
  highlight_parent_comment = highlight_parent_comment,
  sync_selected_comment = sync_selected_comment,
  make_input_win_config = window_helpers.make_input_win_config,
  focus_discussion = window_helpers.focus_discussion,
  focus_input = window_helpers.focus_input,
  input_height = INPUT_HEIGHT,
})

---@param bufnr integer
---@return integer
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

---@param state { discussions: parley.Discussion[], mappings: table<string, parley.anchor.Mapping> }
---@param cursor_line integer
---@return parley.Discussion[]
local function discussions_for_line(state, cursor_line)
  for _, discussion in ipairs(state.discussions) do
    local mapping = state.mappings[discussion.id]
    if mapping and mapping.local_line == cursor_line then
      return { discussion }
    end
  end
  return {}
end

---@param state { discussions: parley.Discussion[] }
---@param discussion_id string
---@return parley.Discussion|nil
local function discussion_by_id(state, discussion_id)
  for _, discussion in ipairs(state.discussions) do
    if discussion.id == discussion_id then
      return discussion
    end
  end
  return nil
end

---@param bufnr integer
---@param instance parley.DiscussionWindowInstance
---@param lines string[]
local function write_lines(bufnr, instance, lines)
  window_helpers.write_lines(bufnr, instance, lines, {
    on_close = function(src_bufnr)
      return M.close(src_bufnr)
    end,
    on_reply = function(src_bufnr)
      return M.reply_current_line(src_bufnr)
    end,
    on_react = function(src_bufnr)
      return M.react_current_comment(src_bufnr)
    end,
    on_edit = function(src_bufnr)
      return M.edit_current_comment(src_bufnr)
    end,
    on_delete = function(src_bufnr)
      return M.delete_current_comment(src_bufnr)
    end,
  })
end

---@param bufnr integer
---@param discussions parley.Discussion[]
---@param mappings table<string, parley.anchor.Mapping>
---@param source_winid integer
---@param source_line integer
---@return boolean
local function open_discussions(bufnr, discussions, mappings, source_winid, source_line)
  local config = M._get_config() or {}
  local float_cfg = config.float or {
    border = "rounded",
    max_width = 80,
    max_height = 30,
  }
  local lines, comment_ranges = render.render_lines(discussions, mappings, {
    format_timestamp = format_timestamp,
  })
  local instance = window_helpers.ensure_instance(M._instances, bufnr, lines, float_cfg, source_winid, source_line, {
    hide_input = input_controller.hide_input,
    input_height = INPUT_HEIGHT,
    on_cursor_moved = sync_selected_comment,
  })
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
---@param bufnr integer
---@return boolean
function M.is_open(bufnr)
  return live_instance(resolve_source_bufnr(bufnr)) ~= nil
end

--- Close the discussion window for `bufnr`.
---@param bufnr integer
---@return boolean
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
---@param bufnr integer
---@param opts? { cursor_line?: integer }
---@return boolean
function M.open_current_line(bufnr, opts)
  opts = opts or {}
  local state = read_service.get_buffer_state(bufnr)
  local instance = live_instance(bufnr)
  local source_winid = window_helpers.resolve_source_winid(bufnr, instance and instance.source_winid or nil)
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
---@param bufnr integer
---@param discussion_id string
---@return boolean
function M.open_discussion(bufnr, discussion_id)
  bufnr = resolve_source_bufnr(bufnr)
  local state = read_service.get_buffer_state(bufnr)
  local instance = live_instance(bufnr)
  local source_winid = window_helpers.resolve_source_winid(bufnr, instance and instance.source_winid or nil)

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
---@param bufnr integer
---@return parley.Discussion|nil
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
---@param bufnr integer
---@return parley.Comment|nil
function M.current_comment(bufnr)
  bufnr = resolve_source_bufnr(bufnr)
  local _, comment = current_selection(bufnr)
  return comment
end

--- Open the reply input for the first discussion on the current line.
---@param bufnr integer
---@return boolean
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

  require("parley.services.write").open_reply_input(bufnr, discussion, parent)
  return true
end

--- React to the currently selected comment.
---@param bufnr integer
---@return boolean
function M.react_current_comment(bufnr)
  bufnr = resolve_source_bufnr(bufnr)
  local ui_state = discussion_ui_state.get(bufnr)
  local discussion, comment = current_selection(bufnr)
  if not discussion or not comment then
    M._notify("Open a Parley discussion before reacting", vim.log.levels.INFO)
    return false
  end

  M._select_reaction(render.reaction_picker_items(comment), function(item)
    if not item then
      return
    end
    require("parley.services.write").react_comment(
      bufnr,
      ui_state and ui_state.current_source_line or nil,
      comment,
      item.reaction
    )
  end)
  return true
end

--- Edit the currently selected comment.
---@param bufnr integer
---@return boolean
function M.edit_current_comment(bufnr)
  bufnr = resolve_source_bufnr(bufnr)
  local discussion, comment = current_selection(bufnr)
  if not discussion or not comment then
    M._notify("Open a Parley discussion before editing", vim.log.levels.INFO)
    return false
  end
  dbg.trace(
    "discussion_window",
    "edit_current_comment: comment.id="
      .. tostring(comment.id)
      .. " author="
      .. tostring(comment.author)
      .. " is_own="
      .. tostring(comment.is_own)
  )
  if not comment.is_own then
    M._notify("You can only edit your own Parley comments", vim.log.levels.WARN)
    return false
  end

  require("parley.services.write").open_edit_input(bufnr, discussion, comment)
  return true
end

--- Delete the currently selected comment.
---@param bufnr integer
---@return boolean
function M.delete_current_comment(bufnr)
  bufnr = resolve_source_bufnr(bufnr)
  local ui_state = discussion_ui_state.get(bufnr)
  local discussion, comment = current_selection(bufnr)
  if not discussion or not comment then
    M._notify("Open a Parley discussion before deleting", vim.log.levels.INFO)
    return false
  end
  dbg.trace(
    "discussion_window",
    "delete_current_comment: comment.id="
      .. tostring(comment.id)
      .. " author="
      .. tostring(comment.author)
      .. " is_own="
      .. tostring(comment.is_own)
  )
  if not comment.is_own then
    M._notify("You can only delete your own Parley comments", vim.log.levels.WARN)
    return false
  end

  local ok =
    require("parley.services.write").delete_comment(bufnr, ui_state and ui_state.current_source_line or nil, comment)
  if ok == false then
    return false
  end
  return true
end

--- Show the embedded input pane for a reply.
---@param bufnr integer
---@param opts {
---   parent_comment_id: string,
---   status: string,
---   on_submit: fun(composer: parley.ComposerHandle, text: string): boolean|nil,
---   initial_text?: string,
--- }
---@return parley.ComposerHandle|nil
function M.show_reply_input(bufnr, opts)
  bufnr = resolve_source_bufnr(bufnr)
  local instance = live_instance(bufnr)
  if not instance or not M.current_discussion(bufnr) then
    M._notify("Open a Parley discussion before replying", vim.log.levels.INFO)
    return nil
  end

  return input_controller.show_input(bufnr, instance, {
    status = opts.status,
    initial_text = opts.initial_text,
    parent_comment_id = opts.parent_comment_id,
    on_submit = opts.on_submit,
  })
end

--- Show the embedded input pane for a new comment.
---@param bufnr integer
---@param opts {
---   cursor_line: integer,
---   status: string,
---   on_submit: fun(composer: parley.ComposerHandle, text: string): boolean|nil,
---   initial_text?: string,
--- }
---@return parley.ComposerHandle|nil
function M.show_new_comment_input(bufnr, opts)
  bufnr = resolve_source_bufnr(bufnr)
  local instance = live_instance(bufnr)
  if not instance then
    local state = read_service.get_buffer_state(bufnr)
    local config = M._get_config() or {}
    local source_winid = window_helpers.resolve_source_winid(bufnr, nil)
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
      local lines, comment_ranges = render.render_lines(discussions, state.mappings, {
        format_timestamp = format_timestamp,
      })
      instance = window_helpers.ensure_instance(M._instances, bufnr, lines, float_cfg, source_winid, opts.cursor_line, {
        hide_input = input_controller.hide_input,
        input_height = INPUT_HEIGHT,
        on_cursor_moved = sync_selected_comment,
      })
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
      instance =
        window_helpers.ensure_instance(M._instances, bufnr, placeholder, float_cfg, source_winid, opts.cursor_line, {
          hide_input = input_controller.hide_input,
          input_height = INPUT_HEIGHT,
          on_cursor_moved = sync_selected_comment,
        })
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

  return input_controller.show_input(bufnr, instance, {
    status = opts.status,
    initial_text = opts.initial_text,
    parent_comment_id = nil,
    on_submit = opts.on_submit,
  })
end

--- Toggle the discussion window for `bufnr`.
---@param bufnr integer
---@return boolean
function M.toggle_current_line(bufnr)
  bufnr = resolve_source_bufnr(bufnr)

  if M.is_open(bufnr) then
    M.close(bufnr)
    return false
  end
  return M.open_current_line(bufnr)
end

return M
