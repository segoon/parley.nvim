--- parley.discussion_window — Discussion window for the current line.
---
--- Opens a floating scratch buffer that renders all discussions anchored to the
--- current cursor line. The content is written as Markdown so users with
--- render-markdown.nvim installed get rich rendering automatically.

local read_service = require("parley.services.read")

local M = {}

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

--- Active window instances keyed by source buffer number.
--- @type table<integer, {
---   bufnr: integer,
---   winid: integer,
---   popup: any|nil,
---   source_winid: integer,
---   close: fun(): nil,
--- }>
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

--- @param seconds integer
--- @param unit string
--- @return string
local function pluralize(seconds, unit)
  if seconds == 1 then
    return string.format("1 %s ago", unit)
  end
  return string.format("%d %ss ago", seconds, unit)
end

--- @param timestamp string
--- @return string
local function format_timestamp(timestamp)
  local epoch = M._strptime("%Y-%m-%dT%H:%M:%SZ", timestamp)
  if not epoch then
    return timestamp
  end

  local delta = math.max(0, M._now() - epoch)
  local ago
  if delta < 3600 then
    ago = pluralize(math.max(1, math.floor(delta / 60)), "min")
  elseif delta < 86400 then
    ago = pluralize(math.floor(delta / 3600), "hour")
  else
    ago = pluralize(math.floor(delta / 86400), "day")
  end

  return string.format("%s (%s)", M._date("%Y-%m-%d %H:%M:%S (%Z)", epoch), ago)
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
local function render_discussion(discussion, mapping, out)
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

    out[#out + 1] = string.format("%s- **%s** · %s", indent, comment.author, format_timestamp(comment.created_at))
    for _, line in ipairs(split_lines(comment.body.text)) do
      out[#out + 1] = string.format("%s  %s", indent, line)
    end

    local reactions = reaction_summary(comment.reactions)
    if reactions then
      out[#out + 1] = string.format("%s  ---", indent)
      out[#out + 1] = string.format("%s  %s", indent, reactions)
    end
    out[#out + 1] = ""
  end
end

--- @param discussions parley.Discussion[]
--- @param mappings table<string, parley.anchor.Mapping>
--- @return string[]
local function render_lines(discussions, mappings)
  local out = {}

  local discussion = discussions[1]
  if not discussion then
    return out
  end

  render_discussion(discussion, mappings[discussion.id], out)

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
--- @param source_winid integer
--- @return {
---   bufnr: integer,
---   winid: integer,
---   popup: any|nil,
---   source_winid: integer,
---   close: fun(): nil,
--- }
local function create_instance(lines, float_cfg, source_winid)
  local config = make_win_config(lines, float_cfg)

  local ok_popup, Popup = pcall(require, "nui.popup")
  if ok_popup then
    local popup = Popup({
      enter = true,
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
      source_winid = source_winid,
      close = function()
        if popup.winid and vim.api.nvim_win_is_valid(popup.winid) then
          popup:unmount()
        end
      end,
    }
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  local winid = vim.api.nvim_open_win(bufnr, true, config)
  local closed = false
  return {
    bufnr = bufnr,
    winid = winid,
    popup = nil,
    source_winid = source_winid,
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
--- @return {
---   bufnr: integer,
---   winid: integer,
---   popup: any|nil,
---   source_winid: integer,
---   close: fun(): nil,
--- }|nil
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

--- @param bufnr integer
--- @return integer
local function resolve_source_bufnr(bufnr)
  if M._instances[bufnr] ~= nil then
    return bufnr
  end

  for source_bufnr, instance in pairs(M._instances) do
    if instance.bufnr == bufnr then
      return source_bufnr
    end
  end

  return bufnr
end

M.resolve_source_bufnr = resolve_source_bufnr

--- @param src_bufnr integer
--- @param instance {
---   bufnr: integer,
---   winid: integer,
---   popup: any|nil,
---   source_winid: integer,
---   close: fun(): nil,
--- }
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

  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = instance.bufnr,
    once = true,
    callback = function()
      vim.schedule(function()
        M.close(src_bufnr)
      end)
    end,
    desc = "Parley: close discussion window when it loses focus",
  })
end

--- @param bufnr integer
--- @param lines string[]
--- @param float_cfg parley.FloatConfig
--- @return {
---   bufnr: integer,
---   winid: integer,
---   popup: any|nil,
---   source_winid: integer,
---   close: fun(): nil,
--- }
local function ensure_instance(bufnr, lines, float_cfg)
  local instance = live_instance(bufnr)
  if instance then
    vim.api.nvim_win_set_config(instance.winid, make_win_config(lines, float_cfg))
    return instance
  end

  instance = create_instance(lines, float_cfg, vim.api.nvim_get_current_win())
  M._instances[bufnr] = instance
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
  local state = read_service.get_buffer_state(bufnr)
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

--- Return the first discussion for the current source buffer line.
--- @param bufnr integer
--- @return parley.Discussion|nil
function M.current_discussion(bufnr)
  bufnr = resolve_source_bufnr(bufnr)
  local state = read_service.get_buffer_state(bufnr)
  if not state then
    return nil
  end

  local source_winid = vim.api.nvim_get_current_win()
  local instance = live_instance(bufnr)
  if
    instance
    and instance.bufnr == vim.api.nvim_get_current_buf()
    and vim.api.nvim_win_is_valid(instance.source_winid)
  then
    source_winid = instance.source_winid
  end
  local cursor_line = vim.api.nvim_win_get_cursor(source_winid)[1]
  local discussions = discussions_for_line(state, cursor_line)
  return discussions[1]
end

--- Open the reply input for the first discussion on the current line.
--- @param bufnr integer
--- @return boolean
function M.reply_current_line(bufnr)
  bufnr = resolve_source_bufnr(bufnr)
  local discussion = M.current_discussion(bufnr)
  if not discussion then
    M._notify("No Parley discussions on this line", vim.log.levels.INFO)
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
