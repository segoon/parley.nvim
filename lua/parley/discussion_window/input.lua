local M = {}

function M.new(deps)
  local function clear_input_status_overlay(instance)
    if instance.input_bufnr and vim.api.nvim_buf_is_valid(instance.input_bufnr) then
      vim.api.nvim_buf_clear_namespace(instance.input_bufnr, deps.input_status_ns, 0, -1)
    end
  end

  local function set_input_status_overlay(instance, status)
    if not instance.input_bufnr or not vim.api.nvim_buf_is_valid(instance.input_bufnr) then
      return
    end
    clear_input_status_overlay(instance)
    vim.api.nvim_buf_set_extmark(instance.input_bufnr, deps.input_status_ns, 0, 0, {
      virt_lines = { { { status, "Comment" } } },
      virt_lines_above = true,
    })
  end

  local function hide_input(instance, force)
    if instance.input_state == "hidden" then
      return true
    end

    if not force then
      if instance.input_state == "submitting" then
        deps.notify("Parley request in progress. Press C to cancel the request.", vim.log.levels.WARN)
        return false
      end

      local text = table.concat(vim.api.nvim_buf_get_lines(instance.input_bufnr, 0, -1, false), "\n")
      if text:match("%S") and not deps.confirm_discard("Are you sure? The draft is not saved and will be lost.") then
        return false
      end
    end

    deps.clear_parent_highlight(instance)
    instance.input_state = "hidden"
    instance.input_cancel = nil
    local source_bufnr = instance.source_bufnr or instance.bufnr
    deps.composer_ui_state.clear(source_bufnr)
    deps.discussion_ui_state.patch(source_bufnr, { input_visible = false, highlighted_parent_comment_id = nil })
    if instance.input_winid and vim.api.nvim_win_is_valid(instance.input_winid) then
      vim.api.nvim_win_close(instance.input_winid, true)
    end
    instance.input_winid = nil
    if instance.input_bufnr and vim.api.nvim_buf_is_valid(instance.input_bufnr) then
      clear_input_status_overlay(instance)
      vim.bo[instance.input_bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(instance.input_bufnr, 0, -1, false, {})
    end
    deps.focus_discussion(instance)
    deps.sync_selected_comment(source_bufnr)
    local on_hidden = instance._on_input_hidden
    instance._on_input_hidden = nil
    if on_hidden then
      on_hidden()
    end
    return true
  end

  local function set_input_status(instance, status)
    if not instance.input_bufnr or not vim.api.nvim_buf_is_valid(instance.input_bufnr) then
      return
    end
    set_input_status_overlay(instance, status)
    vim.bo[instance.input_bufnr].modifiable = true
  end

  local function set_input_submitting(instance, status)
    instance.input_state = "submitting"
    if instance.input_bufnr and vim.api.nvim_buf_is_valid(instance.input_bufnr) then
      set_input_status_overlay(instance, status)
      vim.bo[instance.input_bufnr].modifiable = false
    end
  end

  local function setup_input_keymaps(instance)
    vim.keymap.set("n", "q", function()
      instance.request_close_input()
    end, { buffer = instance.input_bufnr, silent = true, nowait = true, desc = "Close Parley draft" })
    vim.keymap.set("n", "<Esc>", function()
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

  local function show_input(src_bufnr, instance, opts)
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

    local input_cfg = deps.make_input_win_config(
      instance.winid,
      discussion_height,
      width,
      discussion_cfg.border or "rounded",
      deps.input_height
    )
    if instance.input_winid and vim.api.nvim_win_is_valid(instance.input_winid) then
      vim.api.nvim_win_set_config(instance.input_winid, input_cfg)
    else
      instance.input_winid = vim.api.nvim_open_win(instance.input_bufnr, true, input_cfg)
    end

    instance.input_state = "idle"
    instance.input_cancel = nil
    instance._on_input_hidden = opts.on_input_hidden or nil
    deps.discussion_ui_state.patch(src_bufnr, { input_visible = true })

    local composer
    instance.submit_input = function()
      if instance.input_state == "submitting" then
        return
      end

      local text = table.concat(vim.api.nvim_buf_get_lines(instance.input_bufnr, 0, -1, false), "\n")
      if text:match("%S") == nil then
        deps.notify("Parley draft is empty", vim.log.levels.WARN)
        return
      end

      vim.schedule(function()
        if instance.input_state ~= "hidden" then
          opts.on_submit(composer, text)
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
      deps.focus_input(instance)
    end
    instance.set_input_submitting = function(new_status)
      set_input_submitting(instance, new_status)
    end
    instance.focus_discussion = function()
      deps.focus_discussion(instance)
    end
    instance.focus_input = function()
      deps.focus_input(instance)
    end

    composer = {
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

    local body_lines = vim.split(opts.initial_text or "", "\n", { plain = true })
    if #body_lines == 0 then
      body_lines = { "" }
    end
    vim.bo[instance.input_bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(instance.input_bufnr, 0, -1, false, body_lines)
    vim.bo[instance.input_bufnr].modifiable = true
    set_input_status_overlay(instance, opts.status)
    deps.composer_ui_state.patch(src_bufnr, { draft = opts.initial_text or "", visible = true, submit_state = "idle" })
    deps.highlight_parent_comment(instance, opts.parent_comment_id)
    deps.focus_input(instance)
    if instance.input_winid and vim.api.nvim_win_is_valid(instance.input_winid) then
      vim.api.nvim_win_set_cursor(instance.input_winid, { 1, 0 })
    end
    vim.cmd.startinsert()

    return composer
  end

  return {
    hide_input = hide_input,
    show_input = show_input,
  }
end

return M
