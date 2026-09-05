--- Review-wide selection and opening shared by the built-in picker and Telescope.
local entries = require("parley.discussion_entries")
local M = {}
--- @type fun(message: string, level: integer)
M._notify = vim.notify
--- @type fun(path: string)
M._edit = function(path)
  vim.cmd.edit(vim.fn.fnameescape(path))
end
--- @type fun(line: integer)
M._set_cursor = function(line)
  vim.api.nvim_win_set_cursor(0, { line, 0 })
end
--- @type fun(): integer
M._current_buf = vim.api.nvim_get_current_buf
--- @type fun(items: table[], opts: table, callback: fun(item: table|nil))
M._select = function(items, opts, callback)
  require("parley.reaction_picker_window").open(items, opts, callback)
end

--- @param source integer
--- @param value {discussion: parley.Discussion, line?: integer}
--- @param hooks? table Optional UI seams used by the Telescope adapter.
--- @return boolean
function M.open_selection(source, value, hooks)
  hooks = hooks or M
  local read = require("parley.services.read")
  local state = read.get_buffer_state(source)
  if not state or not state.pr or not state.vcs_info then
    return false
  end
  local discussion
  for _, d in ipairs(read.list_discussions(source, { scope = "all" })) do
    if d.id == value.discussion.id then
      discussion = d
      break
    end
  end
  if not discussion then
    M._notify("Parley discussion is no longer available", vim.log.levels.INFO)
    return false
  end
  local location = entries.location(discussion, state.vcs_info.root, state.all_mappings)
  if not location.line or not location.path then
    return require("parley.discussion_window").open_discussion(source, discussion.id)
  end
  hooks._edit(location.path)
  local bufnr = hooks._current_buf()
  read.refresh_async(bufnr, { force = true, notify_errors = true }, function(snapshot)
    if snapshot and snapshot.pr and snapshot.pr.id ~= state.pr.id then
      M._notify("Parley review changed; choose the discussion again", vim.log.levels.INFO)
      return
    end
    local mapping = snapshot and (snapshot.all_mappings or snapshot.mappings or {})[discussion.id]
    local line = value.line
    if mapping then
      line = mapping.local_line
    end
    if line then
      hooks._set_cursor(math.max(1, math.min(line, vim.api.nvim_buf_line_count(bufnr))))
    end
    require("parley.discussion_window").open_discussion(bufnr, discussion.id)
  end)
  return true
end

--- @param bufnr integer
--- @return boolean
function M.open(bufnr)
  bufnr = require("parley.discussion_window").resolve_source_bufnr(bufnr)
  local read = require("parley.services.read")
  local state = read.get_buffer_state(bufnr)
  local discussions = read.list_discussions(bufnr, { scope = "all" })
  if not state or not state.pr or not state.vcs_info or #discussions == 0 then
    M._notify("No Parley discussions in the active review", vim.log.levels.INFO)
    return false
  end
  M._select(discussions, {
    prompt = "Review discussions",
    source_winid = vim.fn.bufwinid(bufnr),
    render_item = function(d)
      return entries.label(d, state.vcs_info.root, state.all_mappings)
    end,
  }, function(d)
    if not d then
      return
    end
    local current = read.get_buffer_state(bufnr)
    if not current or not current.pr or current.pr.id ~= state.pr.id then
      M._notify("Parley review changed; reopen the discussion list", vim.log.levels.INFO)
      return
    end
    local location = entries.location(d, state.vcs_info.root, state.all_mappings)
    M.open_selection(bufnr, { discussion = d, line = location.line })
  end)
  return true
end
local PICKER_PREVIEW_WIDTH = 60

---@param discussion parley.Discussion
---@return string
function M.line_preview(discussion)
  local first = discussion.comments and discussion.comments[1] or nil
  if not first then
    return "(no comments) (?)"
  end

  local body = first.body and first.body.text or ""
  local first_line = vim.split(body, "\n", { plain = true })[1] or ""
  first_line = vim.trim(first_line)
  if first_line == "" then
    first_line = "(empty)"
  end
  if vim.fn.strdisplaywidth(first_line) > PICKER_PREVIEW_WIDTH then
    first_line = vim.fn.strcharpart(first_line, 0, PICKER_PREVIEW_WIDTH - 1) .. "…"
  end

  local extras = math.max(0, #discussion.comments - 1)
  local suffix
  if extras == 0 then
    suffix = ""
  elseif extras == 1 then
    suffix = " (1 more comment)"
  else
    suffix = string.format(" (%d more comments)", extras)
  end

  return string.format("%s (%s)%s", first_line, first.author, suffix)
end

return M
