local M = {}

function M.new(deps)
  ---@param instance table
  local function clear_parent_highlight(instance)
    if vim.api.nvim_buf_is_valid(instance.bufnr) then
      vim.api.nvim_buf_clear_namespace(instance.bufnr, deps.highlight_ns, 0, -1)
    end
  end

  ---@param instance table
  ---@param comment_id string|nil
  local function highlight_parent_comment(instance, comment_id)
    clear_parent_highlight(instance)
    if not comment_id then
      local source_bufnr = instance.source_bufnr or instance.bufnr
      deps.discussion_ui_state.patch(source_bufnr, { highlighted_parent_comment_id = nil })
      return
    end

    local range = instance.comment_ranges[comment_id]
    if not range then
      return
    end

    vim.api.nvim_buf_set_extmark(instance.bufnr, deps.highlight_ns, range.start_line - 1, 0, {
      end_row = range.end_line,
      hl_group = "Visual",
      hl_eol = true,
    })
    local source_bufnr = instance.source_bufnr or instance.bufnr
    deps.discussion_ui_state.patch(source_bufnr, { highlighted_parent_comment_id = comment_id })
  end

  ---@param instance table
  ---@param line integer
  ---@return string|nil
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

  ---@param source_bufnr integer
  ---@return parley.Discussion|nil, parley.Comment|nil, integer|nil
  local function current_selection(source_bufnr)
    local instance = deps.live_instance(source_bufnr)
    local discussion = deps.current_discussion(source_bufnr)
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

  ---@param source_bufnr integer
  local function sync_selected_comment(source_bufnr)
    local instance = deps.live_instance(source_bufnr)
    local discussion, comment = current_selection(source_bufnr)
    if not instance then
      return
    end

    clear_parent_highlight(instance)
    if not discussion or not comment then
      deps.discussion_ui_state.patch(source_bufnr, { selected_comment_id = nil })
      return
    end

    local range = instance.comment_ranges[comment.id]
    if range then
      vim.api.nvim_buf_set_extmark(instance.bufnr, deps.highlight_ns, range.start_line - 1, 0, {
        end_row = range.end_line,
        hl_group = "Visual",
        hl_eol = true,
      })
    end
    deps.discussion_ui_state.patch(source_bufnr, { selected_comment_id = comment.id })
  end

  return {
    clear_parent_highlight = clear_parent_highlight,
    highlight_parent_comment = highlight_parent_comment,
    current_selection = current_selection,
    sync_selected_comment = sync_selected_comment,
  }
end

return M
