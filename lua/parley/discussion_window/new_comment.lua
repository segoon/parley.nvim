local M = {}
--- @param bufnr integer
--- @param opts table
--- @param deps table
--- @return parley.ComposerHandle|nil
function M.show(bufnr, opts, deps)
  bufnr = deps.resolve_source_bufnr(bufnr)
  local instance = deps.live_instance(bufnr)
  local on_input_hidden = nil
  if not instance then
    local state = deps.read_service.get_buffer_state(bufnr)
    local config = deps.get_config() or {}
    local source_winid = deps.window_helpers.resolve_source_winid(bufnr, nil)
    local float_cfg = config.float or {
      border = "rounded",
      max_width = 80,
      max_height = 30,
    }
    if not source_winid then
      deps.notify("Open the source buffer to write a Parley comment", vim.log.levels.INFO)
      return nil
    end
    local discussions = state and deps.discussions_for_line(state, opts.cursor_line) or {}
    if #discussions > 0 then
      local lines, comment_ranges, title = deps.render.render_lines(discussions, state.mappings, {
        format_timestamp = deps.format_timestamp,
        reaction_presentation = deps.reactions.presentation(bufnr),
      })
      instance =
        deps.window_helpers.ensure_instance(deps.instances, bufnr, lines, float_cfg, source_winid, opts.cursor_line, {
          hide_input = deps.input_controller.hide_input,
          input_height = deps.INPUT_HEIGHT,
          on_cursor_moved = deps.sync_selected_comment,
          title = title,
        })
      instance.comment_ranges = comment_ranges
      deps.write_lines(bufnr, instance, lines)
      deps.discussion_ui_state.set(bufnr, {
        visible = true,
        current_discussion_id = discussions[1].id,
        current_source_line = opts.cursor_line,
        highlighted_parent_comment_id = nil,
        selected_comment_id = nil,
        input_visible = false,
      })
    else
      local placeholder = { "_No discussion on this line yet._" }
      instance = deps.window_helpers.ensure_instance(
        deps.instances,
        bufnr,
        placeholder,
        float_cfg,
        source_winid,
        opts.cursor_line,
        {
          hide_input = deps.input_controller.hide_input,
          input_height = deps.INPUT_HEIGHT,
          on_cursor_moved = deps.sync_selected_comment,
        }
      )
      instance.comment_ranges = {}
      deps.write_lines(bufnr, instance, placeholder)
      deps.discussion_ui_state.set(bufnr, {
        visible = true,
        current_discussion_id = nil,
        current_source_line = opts.cursor_line,
        highlighted_parent_comment_id = nil,
        selected_comment_id = nil,
        input_visible = false,
      })
      -- No existing discussion: the window was opened only to host the input.
      -- Close it automatically when the input is dismissed.
      on_input_hidden = function()
        deps.close(bufnr)
      end
    end
  end

  return deps.input_controller.show_input(bufnr, instance, {
    status = opts.status,
    initial_text = opts.initial_text,
    parent_comment_id = nil,
    on_submit = opts.on_submit,
    on_input_hidden = on_input_hidden,
  })
end
return M
