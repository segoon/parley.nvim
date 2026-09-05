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
  local display = entries.label(discussion, state.vcs_info.root, state.all_mappings)
  return {
    value = {
      discussion = discussion,
      path = location.path,
      line = location.line,
    },
    display = display,
    ordinal = table.concat({ discussion.file or "", tostring(location.line), location.status, location.preview }, " "),
  }
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
          local entry = action_state.get_selected_entry()
          if entry then
            require("parley.discussion_picker").open_selection(bufnr, entry.value or entry, M)
          end
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
