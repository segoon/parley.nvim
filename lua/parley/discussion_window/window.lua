local M = {}

---@param lines string[]
---@param max_width integer
---@return integer
local function window_width(lines, max_width)
  local width = 20
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  return math.min(max_width, width)
end

---@param lines string[]
---@param float_cfg parley.FloatConfig
---@param source_winid integer
---@param _source_line integer  unused for positioning; retained for API stability
---@param title string|nil
---@return vim.api.keyset.win_config
function M.make_win_config(lines, float_cfg, source_winid, _source_line, title)
  local width = window_width(lines, float_cfg.max_width)
  local height = math.min(float_cfg.max_height, math.max(1, #lines))

  local win_width = vim.api.nvim_win_get_width(source_winid)
  local win_height = vim.api.nvim_win_get_height(source_winid)
  width = math.min(width, math.max(12, win_width - 4))
  height = math.min(height, math.max(1, win_height - 2))

  local config = {
    relative = "win",
    win = source_winid,
    row = math.max(0, math.floor((win_height - height) / 2)),
    col = math.max(0, math.floor((win_width - width) / 2)),
    style = "minimal",
    border = float_cfg.border,
    width = width,
    height = height,
    focusable = true,
  }

  if title and title ~= "" then
    config.title = title
    config.title_pos = "left"
  end

  return config
end

---@param discussion_winid integer
---@param discussion_height integer
---@param width integer
---@param border string
---@param input_height integer
---@return vim.api.keyset.win_config
function M.make_input_win_config(discussion_winid, discussion_height, width, border, input_height)
  local pos = vim.api.nvim_win_get_position(discussion_winid)
  return {
    relative = "editor",
    row = pos[1] + discussion_height + 2,
    col = pos[2],
    style = "minimal",
    border = border,
    width = width,
    height = input_height,
    focusable = true,
  }
end

---@param instance table
function M.focus_discussion(instance)
  if vim.api.nvim_win_is_valid(instance.winid) then
    vim.api.nvim_set_current_win(instance.winid)
  end
end

---@param instance table
function M.focus_input(instance)
  if instance.input_winid and vim.api.nvim_win_is_valid(instance.input_winid) then
    vim.api.nvim_set_current_win(instance.input_winid)
  end
end

---@param bufnr integer
---@param winid integer|nil
---@return boolean
local function is_source_window(bufnr, winid)
  return winid ~= nil and vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr
end

---@param bufnr integer
---@param preferred_winid integer|nil
---@return integer|nil
function M.resolve_source_winid(bufnr, preferred_winid)
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

---@param instances table<integer, parley.DiscussionWindowInstance>
---@param bufnr integer
---@return parley.DiscussionWindowInstance|nil
function M.live_instance(instances, bufnr)
  local instance = instances[bufnr]
  if not instance then
    return nil
  end
  if not vim.api.nvim_buf_is_valid(instance.bufnr) or not vim.api.nvim_win_is_valid(instance.winid) then
    instances[bufnr] = nil
    return nil
  end
  return instance
end

---@param lines string[]
---@param float_cfg parley.FloatConfig
---@param source_winid integer
---@param source_line integer
---@param opts { hide_input: fun(instance: parley.DiscussionWindowInstance, force: boolean): boolean, title?: string }
---@return parley.DiscussionWindowInstance
function M.create_instance(lines, float_cfg, source_winid, source_line, opts)
  local config = M.make_win_config(lines, float_cfg, source_winid, source_line, opts.title)
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
      opts.hide_input(instance, true)
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
    M.focus_discussion(instance)
  end
  instance.focus_input = function()
    M.focus_input(instance)
  end
  return instance
end

---@param src_bufnr integer
---@param instance parley.DiscussionWindowInstance
---@param lines string[]
---@param opts {
---@param on_close fun(bufnr: integer): boolean,
---@param on_reply fun(bufnr: integer): boolean,
---@param on_react fun(bufnr: integer): boolean,
---@param on_edit fun(bufnr: integer): boolean,
---@param on_delete fun(bufnr: integer): boolean,
---@param }
function M.write_lines(src_bufnr, instance, lines, opts)
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
    opts.on_close(src_bufnr)
  end, { buffer = instance.bufnr, silent = true, nowait = true, desc = "Close Parley discussion" })
  vim.keymap.set("n", "r", function()
    opts.on_reply(src_bufnr)
  end, { buffer = instance.bufnr, silent = true, nowait = true, desc = "Reply in Parley discussion" })
  vim.keymap.set("n", "R", function()
    opts.on_react(src_bufnr)
  end, { buffer = instance.bufnr, silent = true, nowait = true, desc = "React to Parley comment" })
  vim.keymap.set("n", "e", function()
    opts.on_edit(src_bufnr)
  end, { buffer = instance.bufnr, silent = true, nowait = true, desc = "Edit Parley comment" })
  vim.keymap.set("n", "d", function()
    opts.on_delete(src_bufnr)
  end, { buffer = instance.bufnr, silent = true, nowait = true, desc = "Delete Parley comment" })
end

---@param instances table<integer, parley.DiscussionWindowInstance>
---@param bufnr integer
---@param lines string[]
---@param float_cfg parley.FloatConfig
---@param source_winid integer
---@param source_line integer
---@param opts {
---@param hide_input fun(instance: parley.DiscussionWindowInstance, force: boolean): boolean,
---@param input_height integer,
---@param on_cursor_moved fun(bufnr: integer): nil,
---@param title? string|nil,
---@param }
---@return parley.DiscussionWindowInstance
function M.ensure_instance(instances, bufnr, lines, float_cfg, source_winid, source_line, opts)
  local instance = M.live_instance(instances, bufnr)
  if instance then
    instance.source_bufnr = bufnr
    instance.source_winid = source_winid
    vim.api.nvim_win_set_config(
      instance.winid,
      M.make_win_config(lines, float_cfg, source_winid, source_line, opts.title)
    )
    if instance.input_winid and vim.api.nvim_win_is_valid(instance.input_winid) then
      local discussion_cfg = vim.api.nvim_win_get_config(instance.winid)
      vim.api.nvim_win_set_config(
        instance.input_winid,
        M.make_input_win_config(
          instance.winid,
          discussion_cfg.height or #lines,
          discussion_cfg.width or 20,
          discussion_cfg.border,
          opts.input_height
        )
      )
    end
    return instance
  end

  instance = M.create_instance(lines, float_cfg, source_winid, source_line, {
    hide_input = opts.hide_input,
    title = opts.title,
  })
  instance.source_bufnr = bufnr
  instances[bufnr] = instance
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = instance.bufnr,
    callback = function()
      opts.on_cursor_moved(bufnr)
    end,
    desc = "Parley: highlight selected discussion comment",
  })
  return instance
end

return M
