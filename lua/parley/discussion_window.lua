--- parley.discussion_window — Discussion window for the current line.
---
--- Opens a floating scratch buffer that renders all discussions anchored to the
--- current cursor line. The content is written as Markdown so users with
--- render-markdown.nvim installed get rich rendering automatically.

local orchestrator = require("parley.orchestrator")

local M = {}

--- Active window instances keyed by source buffer number.
--- @type table<integer, { bufnr: integer, winid: integer, popup: any|nil, close: fun(): nil }>
M._instances = {}

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
    parts[#parts + 1] = string.format("`%s` x%d%s", reaction.type, reaction.count, suffix)
  end
  return table.concat(parts, ", ")
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
--- @param index integer
--- @param out string[]
local function render_discussion(discussion, mapping, index, out)
  local status = discussion.resolved and "resolved" or "unresolved"
  local header = string.format("## Thread %d · %s", index, status)
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

    out[#out + 1] = string.format("%s- **%s** · %s", indent, comment.author, comment.created_at)
    for _, line in ipairs(split_lines(comment.body.text)) do
      out[#out + 1] = string.format("%s  %s", indent, line)
    end

    local reactions = reaction_summary(comment.reactions)
    if reactions then
      out[#out + 1] = string.format("%s  Reactions: %s", indent, reactions)
    end
    out[#out + 1] = ""
  end
end

--- @param discussions parley.Discussion[]
--- @param mappings table<string, parley.anchor.Mapping>
--- @return string[]
local function render_lines(discussions, mappings)
  local out = { "# Parley Discussion", "" }

  for i, discussion in ipairs(discussions) do
    render_discussion(discussion, mappings[discussion.id], i, out)
  end

  while #out > 0 and out[#out] == "" do
    table.remove(out)
  end

  return out
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
--- @return vim.api.keyset.win_config
local function make_win_config(lines, float_cfg)
  return {
    relative = "cursor",
    row = 1,
    col = 0,
    style = "minimal",
    border = float_cfg.border,
    width = window_width(lines, float_cfg.max_width),
    height = math.min(float_cfg.max_height, math.max(1, #lines)),
    focusable = true,
  }
end

--- @param lines string[]
--- @param float_cfg parley.FloatConfig
--- @return { bufnr: integer, winid: integer, popup: any|nil, close: fun(): nil }
local function create_instance(lines, float_cfg)
  local config = make_win_config(lines, float_cfg)

  local ok_popup, Popup = pcall(require, "nui.popup")
  if ok_popup then
    local popup = Popup({
      enter = false,
      focusable = true,
      relative = "cursor",
      position = { row = config.row, col = config.col },
      size = { width = config.width, height = config.height },
      border = { style = config.border },
    })
    popup:mount()
    return {
      bufnr = popup.bufnr,
      winid = popup.winid,
      popup = popup,
      close = function()
        if popup.winid and vim.api.nvim_win_is_valid(popup.winid) then
          popup:unmount()
        end
      end,
    }
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  local winid = vim.api.nvim_open_win(bufnr, false, config)
  local closed = false
  return {
    bufnr = bufnr,
    winid = winid,
    popup = nil,
    close = function()
      if closed then
        return
      end
      closed = true
      if vim.api.nvim_win_is_valid(winid) then
        vim.api.nvim_win_close(winid, true)
      end
    end,
  }
end

--- @param bufnr integer
--- @return { bufnr: integer, winid: integer, popup: any|nil, close: fun(): nil }|nil
local function live_instance(bufnr)
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

--- @param src_bufnr integer
--- @param instance { bufnr: integer, winid: integer, popup: any|nil, close: fun(): nil }
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
end

--- @param bufnr integer
--- @param lines string[]
--- @param float_cfg parley.FloatConfig
--- @return { bufnr: integer, winid: integer, popup: any|nil, close: fun(): nil }
local function ensure_instance(bufnr, lines, float_cfg)
  local instance = live_instance(bufnr)
  if instance then
    vim.api.nvim_win_set_config(instance.winid, make_win_config(lines, float_cfg))
    return instance
  end

  instance = create_instance(lines, float_cfg)
  M._instances[bufnr] = instance
  return instance
end

--- @param state { discussions: parley.Discussion[], mappings: table<string, parley.anchor.Mapping> }
--- @param cursor_line integer
--- @return parley.Discussion[]
local function discussions_for_line(state, cursor_line)
  local out = {}
  for _, discussion in ipairs(state.discussions) do
    local mapping = state.mappings[discussion.id]
    if mapping and mapping.local_line == cursor_line then
      out[#out + 1] = discussion
    end
  end
  return out
end

--- Return whether the discussion window is open for `bufnr`.
--- @param bufnr integer
--- @return boolean
function M.is_open(bufnr)
  return live_instance(bufnr) ~= nil
end

--- Close the discussion window for `bufnr`.
--- @param bufnr integer
--- @return boolean  true when a window was closed
function M.close(bufnr)
  local instance = live_instance(bufnr)
  if not instance then
    M._instances[bufnr] = nil
    return false
  end

  M._instances[bufnr] = nil
  instance.close()
  return true
end

--- Open the discussion window for the current line in `bufnr`.
--- @param bufnr integer
--- @return boolean  true when a window was opened or updated
function M.open_current_line(bufnr)
  local state = orchestrator.get_buffer_state(bufnr)
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]

  if not state then
    M.close(bufnr)
    M._notify("No Parley discussions on this line", vim.log.levels.INFO)
    return false
  end

  local discussions = discussions_for_line(state, cursor_line)
  if #discussions == 0 then
    M.close(bufnr)
    M._notify("No Parley discussions on this line", vim.log.levels.INFO)
    return false
  end

  local config = M._get_config() or {}
  local float_cfg = config.float or {
    border = "rounded",
    max_width = 80,
    max_height = 30,
  }
  local lines = render_lines(discussions, state.mappings)
  local instance = ensure_instance(bufnr, lines, float_cfg)
  write_lines(bufnr, instance, lines)
  return true
end

--- Toggle the discussion window for `bufnr`.
--- @param bufnr integer
--- @return boolean  true when a window ends up open
function M.toggle_current_line(bufnr)
  if M.is_open(bufnr) then
    M.close(bufnr)
    return false
  end
  return M.open_current_line(bufnr)
end

return M
