--- parley.telescope — optional Telescope pickers for Parley discussions.

local entries = require("parley.discussion_entries")

local M = {}

M._notify = function(msg, level)
  vim.notify(msg, level)
end

M._edit = function(path)
  vim.cmd.edit(vim.fn.fnameescape(path))
end

M._set_cursor = function(line)
  vim.api.nvim_win_set_cursor(0, { line, 0 })
end

--- @return integer
M._current_buf = function()
  return vim.api.nvim_get_current_buf()
end

--- @return table|nil, table|nil, table|nil, table|nil, table|nil
local function load_telescope()
  local ok_pickers, pickers = pcall(require, "telescope.pickers")
  local ok_finders, finders = pcall(require, "telescope.finders")
  local ok_config, config = pcall(require, "telescope.config")
  local ok_actions, actions = pcall(require, "telescope.actions")
  local ok_action_state, action_state = pcall(require, "telescope.actions.state")
  if not (ok_pickers and ok_finders and ok_config and ok_actions and ok_action_state) then
    return nil, nil, nil, nil, nil
  end
  return pickers, finders, config.values, actions, action_state
end

--- @param state table
--- @param discussion parley.Discussion
--- @return table
local function make_entry(state, discussion)
  local location = entries.location(discussion, state.vcs_info.root, state.all_mappings)
  local display = string.format("%s:%d [%s] %s", discussion.file, location.line, location.status, location.preview)
  return {
    value = {
      discussion = discussion,
      path = location.path,
      line = location.line,
    },
    display = display,
    ordinal = table.concat({ discussion.file, tostring(location.line), location.status, location.preview }, " "),
  }
end

--- @param entry table|nil
local function open_selection(entry)
  local value = entry and (entry.value or entry) or nil
  local discussion = value and value.discussion or nil
  local path = value and value.path or nil
  local line = value and value.line or nil
  if not discussion or not path then
    return
  end

  M._edit(path)
  local bufnr = M._current_buf()
  if line then
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    if line_count >= 1 then
      M._set_cursor(math.max(1, math.min(line, line_count)))
    end
  end
  require("parley.services.read").refresh_async(bufnr, { force = true, notify_errors = true }, function(snapshot)
    if not line then
      local mapping = snapshot and snapshot.all_mappings and snapshot.all_mappings[discussion.id]
        or snapshot and snapshot.mappings and snapshot.mappings[discussion.id]
        or nil
      local local_line = mapping and mapping.local_line or nil
      local line_count = vim.api.nvim_buf_line_count(bufnr)
      if local_line and line_count >= 1 then
        M._set_cursor(math.max(1, math.min(local_line, line_count)))
      end
    end
    require("parley.discussion_window").open_discussion(bufnr, discussion.id)
  end)
end

--- @param scope 'file'|'all'
--- @param prompt_title string
--- @param opts? table
--- @return boolean
local function open_picker(scope, prompt_title, opts)
  opts = opts or {}
  local pickers, finders, conf, actions, action_state = load_telescope()
  if not pickers then
    M._notify("parley: telescope.nvim is not installed", vim.log.levels.WARN)
    return false
  end

  local bufnr = opts.bufnr or M._current_buf()
  local read_service = require("parley.services.read")
  local state = read_service.get_buffer_state(bufnr)
  if not state or not state.pr or not state.vcs_info or not state.vcs_info.root then
    M._notify("parley: no active PR discussions for this buffer", vim.log.levels.INFO)
    return false
  end

  local discussions = read_service.list_discussions(bufnr, { scope = scope })
  pickers
    .new(opts, {
      prompt_title = prompt_title,
      finder = finders.new_table({
        results = discussions,
        entry_maker = function(discussion)
          return make_entry(state, discussion)
        end,
      }),
      sorter = conf.generic_sorter(opts),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          actions.close(prompt_bufnr)
          open_selection(action_state.get_selected_entry())
        end)
        return true
      end,
    })
    :find()

  return true
end

--- @param opts? table
--- @return boolean
function M.discussions(opts)
  return open_picker("all", "Parley Discussions", opts)
end

--- @param opts? table
--- @return boolean
function M.discussions_file(opts)
  return open_picker("file", "Parley Discussions (File)", opts)
end

return M
