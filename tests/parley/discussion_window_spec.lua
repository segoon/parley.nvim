--- tests/parley/discussion_window_spec.lua — Discussion window (Step 13)

local discussion_window = require("parley.discussion_window")
local model = require("parley.model")
local composer_ui_state = require("parley.ui_states.composer")
local discussion_ui_state = require("parley.ui_states.discussion")
local read_service = require("parley.services.read")
local review_repository = require("parley.repositories.review")

local INPUT_STATUS_NS = vim.api.nvim_create_namespace("parley.discussion_window.input_status")

--- @param n integer
--- @return integer
local function scratch(n)
  local bufnr = vim.api.nvim_create_buf(false, true)
  local lines = {}
  for _ = 1, n do
    lines[#lines + 1] = ""
  end
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(bufnr)
  return bufnr
end

--- @param opts? table
--- @return parley.Comment
local function make_comment(opts)
  opts = opts or {}
  local id = opts.id or "c1"
  return model.new_comment({
    id = id,
    author = opts.author or "alice",
    body = model.new_body({ text = opts.text or "Hello", format = "markdown" }),
    created_at = opts.created_at or "2024-01-01T10:00:00Z",
    updated_at = opts.updated_at or "2024-01-01T10:00:00Z",
    reactions = opts.reactions or {},
    is_own = opts.is_own or false,
    parent_comment_id = opts.parent_comment_id,
  })
end

--- @param opts? table
--- @return parley.Discussion
local function make_discussion(opts)
  opts = opts or {}
  return model.new_discussion({
    id = opts.id or "d1",
    file = opts.file or "src/foo.lua",
    line = opts.line or 3,
    resolved = opts.resolved or false,
    comments = opts.comments or {
      make_comment({ id = "c1", text = opts.text or "First comment" }),
    },
  })
end

local saved = {}
local notify_calls = {}

local function save_seams()
  saved.get_config = discussion_window._get_config
  saved.notify = discussion_window._notify
  saved.now = discussion_window._now
  saved.date = discussion_window._date
  saved.strptime = discussion_window._strptime
  saved.confirm_discard = discussion_window._confirm_discard
  saved.select = discussion_window._select_reaction
  saved.write = package.loaded["parley.services.write"]
end

local function restore_seams()
  discussion_window._get_config = saved.get_config
  discussion_window._notify = saved.notify
  discussion_window._now = saved.now
  discussion_window._date = saved.date
  discussion_window._strptime = saved.strptime
  discussion_window._confirm_discard = saved.confirm_discard
  discussion_window._select_reaction = saved.select
  package.loaded["parley.services.write"] = saved.write
end

describe("parley.discussion_window", function()
  before_each(function()
    save_seams()
    notify_calls = {}
    discussion_window._get_config = function()
      return {
        float = {
          border = "rounded",
          max_width = 80,
          max_height = 30,
        },
      }
    end
    discussion_window._notify = function(msg, level)
      notify_calls[#notify_calls + 1] = { msg = msg, level = level }
    end
    discussion_window._now = function()
      return 160
    end
    discussion_window._strptime = function(_fmt, value)
      local epochs = {
        ["2024-01-01T10:00:00Z"] = 100,
        ["2024-01-01T10:00:01Z"] = 101,
      }
      return epochs[value]
    end
    discussion_window._date = function(fmt, epoch)
      if fmt == "%Y-%m-%d %H:%M:%S (%Z)" then
        local values = {
          [100] = "2026-05-08 15:08:38 (MSK)",
          [101] = "2026-05-08 15:08:39 (MSK)",
        }
        return values[epoch]
      end
      error("unexpected date format in test: " .. tostring(fmt))
    end
    discussion_window._select_reaction = function(_items, on_choice)
      on_choice(nil)
    end
    for bufnr in pairs(discussion_window._instances) do
      discussion_window.close(bufnr)
    end
    for bufnr in pairs(review_repository._entries) do
      read_service.clear_buffer_state(bufnr)
    end
    discussion_ui_state._entries = {}
    composer_ui_state._entries = {}
  end)

  after_each(function()
    for bufnr in pairs(discussion_window._instances) do
      discussion_window.close(bufnr)
    end
    for bufnr in pairs(review_repository._entries) do
      read_service.clear_buffer_state(bufnr)
    end
    discussion_ui_state._entries = {}
    composer_ui_state._entries = {}
    restore_seams()
  end)

  it("opens a window for discussions on the current line", function()
    local bufnr = scratch(10)
    local source_winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(0, { 3, 0 })

    review_repository._entries[bufnr] = {
      status = "ready",
      stale = false,
      discussions = { make_discussion({ line = 3, text = "Review this nil guard" }) },
      mappings = {
        d1 = { local_line = 3, stale = false, confidence = 1.0 },
      },
    }

    local ok = discussion_window.open_current_line(bufnr)
    local instance = discussion_window._instances[bufnr]

    assert.is_true(ok)
    assert.is_true(discussion_window.is_open(bufnr))
    assert.is_not_nil(instance)
    assert.is_true(vim.api.nvim_win_is_valid(instance.winid))
    assert.equal(instance.winid, vim.api.nvim_get_current_win())
    assert.equal(source_winid, instance.source_winid)

    local lines = vim.api.nvim_buf_get_lines(instance.bufnr, 0, -1, false)
    assert.is_false(vim.tbl_contains(lines, "# Parley Discussion"))
    assert.is_false(vim.tbl_contains(lines, "## Thread 1 · unresolved"))
    assert.is_not_nil(vim.tbl_contains(lines, "unresolved"))
    assert.is_not_nil(vim.tbl_contains(lines, "Review this nil guard"))
  end)

  it("notifies and stays closed when the current line has no discussions", function()
    local bufnr = scratch(10)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    review_repository._entries[bufnr] = {
      status = "ready",
      stale = false,
      discussions = { make_discussion({ line = 3 }) },
      mappings = {
        d1 = { local_line = 3, stale = false, confidence = 1.0 },
      },
    }

    local ok = discussion_window.open_current_line(bufnr)

    assert.is_false(ok)
    assert.is_false(discussion_window.is_open(bufnr))
    assert.equal(1, #notify_calls)
    assert.equal(vim.log.levels.INFO, notify_calls[1].level)
  end)

  it("toggle_current_line opens, then closes the existing window", function()
    local bufnr = scratch(10)
    local source_winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(0, { 3, 0 })

    review_repository._entries[bufnr] = {
      status = "ready",
      stale = false,
      discussions = { make_discussion({ line = 3 }) },
      mappings = {
        d1 = { local_line = 3, stale = false, confidence = 1.0 },
      },
    }

    assert.is_true(discussion_window.toggle_current_line(bufnr))
    assert.is_true(discussion_window.is_open(bufnr))
    assert.equal(discussion_window._instances[bufnr].winid, vim.api.nvim_get_current_win())

    assert.is_false(discussion_window.toggle_current_line(discussion_window._instances[bufnr].bufnr))
    assert.is_false(discussion_window.is_open(bufnr))
    assert.equal(source_winid, vim.api.nvim_get_current_win())
  end)

  it("renders nested replies using parent_comment_id indentation", function()
    local bufnr = scratch(10)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })

    review_repository._entries[bufnr] = {
      status = "ready",
      stale = false,
      discussions = {
        make_discussion({
          line = 3,
          comments = {
            make_comment({ id = "c1", author = "alice", text = "Root comment" }),
            make_comment({ id = "c2", author = "bob", text = "Reply comment", parent_comment_id = "c1" }),
          },
        }),
      },
      mappings = {
        d1 = { local_line = 3, stale = false, confidence = 1.0 },
      },
    }

    discussion_window.open_current_line(bufnr)
    local instance = discussion_window._instances[bufnr]
    local lines = vim.api.nvim_buf_get_lines(instance.bufnr, 0, -1, false)

    assert.is_not_nil(vim.tbl_contains(lines, "- **alice** · 2026-05-08 15:08:38 (MSK) (1 min ago)"))
    assert.is_not_nil(vim.tbl_contains(lines, "  - **bob** · 2026-05-08 15:08:38 (MSK) (1 min ago)"))
    assert.is_not_nil(vim.tbl_contains(lines, "    Reply comment"))
  end)

  it("renders emoji reactions and omits x1 counts", function()
    local bufnr = scratch(10)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })

    review_repository._entries[bufnr] = {
      status = "ready",
      stale = false,
      discussions = {
        make_discussion({
          line = 3,
          comments = {
            make_comment({
              id = "c1",
              author = "alice",
              text = "Root comment",
              reactions = {
                model.new_reaction({ type = "+1", count = 1, viewer_reacted = false }),
                model.new_reaction({ type = "heart", count = 2, viewer_reacted = true }),
              },
            }),
          },
        }),
      },
      mappings = {
        d1 = { local_line = 3, stale = false, confidence = 1.0 },
      },
    }

    discussion_window.open_current_line(bufnr)
    local instance = discussion_window._instances[bufnr]
    local lines = vim.api.nvim_buf_get_lines(instance.bufnr, 0, -1, false)

    assert.is_not_nil(vim.tbl_contains(lines, "  Reactions: 👍, ❤️ x2 (you)"))
  end)

  it("renders only the first discussion on a commented line", function()
    local bufnr = scratch(10)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })

    review_repository._entries[bufnr] = {
      status = "ready",
      stale = false,
      discussions = {
        make_discussion({ id = "d1", line = 3, text = "First discussion" }),
        make_discussion({ id = "d2", line = 3, text = "Second discussion" }),
      },
      mappings = {
        d1 = { local_line = 3, stale = false, confidence = 1.0 },
        d2 = { local_line = 3, stale = false, confidence = 1.0 },
      },
    }

    discussion_window.open_current_line(bufnr)
    local instance = discussion_window._instances[bufnr]
    local lines = vim.api.nvim_buf_get_lines(instance.bufnr, 0, -1, false)

    assert.is_not_nil(vim.tbl_contains(lines, "First discussion"))
    assert.is_false(vim.tbl_contains(lines, "Second discussion"))
  end)

  it("shows an embedded reply input and highlights the parent comment", function()
    local bufnr = scratch(10)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })

    review_repository._entries[bufnr] = {
      status = "ready",
      stale = false,
      discussions = {
        make_discussion({
          line = 3,
          comments = {
            make_comment({ id = "c1", text = "Parent comment" }),
            make_comment({ id = "c2", text = "Child comment", parent_comment_id = "c1" }),
          },
        }),
      },
      mappings = {
        d1 = { local_line = 3, stale = false, confidence = 1.0 },
      },
    }

    discussion_window.open_current_line(bufnr)
    local composer = discussion_window.show_reply_input(bufnr, {
      parent_comment_id = "c1",
      status = "Reply draft",
      on_submit = function() end,
    })
    local instance = discussion_window._instances[bufnr]

    assert.is_not_nil(composer)
    assert.is_not_nil(instance.input_winid)
    assert.is_true(vim.api.nvim_win_is_valid(instance.input_winid))

    local highlights = vim.api.nvim_buf_get_extmarks(
      instance.bufnr,
      vim.api.nvim_create_namespace("parley.discussion_window"),
      0,
      -1,
      {}
    )
    assert.is_true(#highlights >= 1)
  end)

  it("tracks and highlights the comment under the float cursor", function()
    local bufnr = scratch(10)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })

    review_repository._entries[bufnr] = {
      status = "ready",
      stale = false,
      discussions = {
        make_discussion({
          line = 3,
          comments = {
            make_comment({ id = "c1", text = "Parent comment" }),
            make_comment({ id = "c2", text = "Child comment", parent_comment_id = "c1" }),
          },
        }),
      },
      mappings = {
        d1 = { local_line = 3, stale = false, confidence = 1.0 },
      },
    }

    discussion_window.open_current_line(bufnr)
    local instance = discussion_window._instances[bufnr]
    vim.api.nvim_win_set_cursor(instance.winid, { 1, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { modeline = false })

    assert.equals("c1", discussion_window.current_comment(bufnr).id)
    assert.equals("c1", discussion_ui_state.get(bufnr).selected_comment_id)

    vim.api.nvim_win_set_cursor(instance.winid, { 5, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { modeline = false })

    assert.equals("c2", discussion_window.current_comment(bufnr).id)
    assert.equals("c2", discussion_ui_state.get(bufnr).selected_comment_id)
  end)

  it("reacts to the selected comment from the float", function()
    local bufnr = scratch(10)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    local calls = {}

    review_repository._entries[bufnr] = {
      status = "ready",
      stale = false,
      discussions = {
        make_discussion({
          line = 3,
          comments = {
            make_comment({ id = "c1", text = "Parent comment" }),
          },
        }),
      },
      mappings = {
        d1 = { local_line = 3, stale = false, confidence = 1.0 },
      },
    }
    package.loaded["parley.services.write"] = {
      react_comment = function(src_bufnr, cursor_line, comment_id, reaction)
        calls[#calls + 1] =
          { bufnr = src_bufnr, cursor_line = cursor_line, comment_id = comment_id, reaction = reaction }
      end,
    }
    discussion_window._select_reaction = function(_items, on_choice)
      on_choice({ reaction = "heart" })
    end

    discussion_window.open_current_line(bufnr)
    assert.is_true(discussion_window.react_current_comment(bufnr))
    assert.same({ { bufnr = bufnr, cursor_line = 3, comment_id = "c1", reaction = "heart" } }, calls)
  end)

  it("opens edit for the selected own comment", function()
    local bufnr = scratch(10)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    local calls = {}

    review_repository._entries[bufnr] = {
      status = "ready",
      stale = false,
      discussions = {
        make_discussion({
          line = 3,
          comments = {
            make_comment({ id = "c1", text = "Editable", is_own = true }),
          },
        }),
      },
      mappings = {
        d1 = { local_line = 3, stale = false, confidence = 1.0 },
      },
    }
    package.loaded["parley.services.write"] = {
      open_edit_input = function(src_bufnr, discussion_id, comment_id, text)
        calls[#calls + 1] = { bufnr = src_bufnr, discussion_id = discussion_id, comment_id = comment_id, text = text }
      end,
    }

    discussion_window.open_current_line(bufnr)
    assert.is_true(discussion_window.edit_current_comment(bufnr))
    assert.same({ { bufnr = bufnr, discussion_id = "d1", comment_id = "c1", text = "Editable" } }, calls)
  end)

  it("requires ownership before editing or deleting", function()
    local bufnr = scratch(10)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })

    review_repository._entries[bufnr] = {
      status = "ready",
      stale = false,
      discussions = {
        make_discussion({
          line = 3,
          comments = {
            make_comment({ id = "c1", text = "Not yours", is_own = false }),
          },
        }),
      },
      mappings = {
        d1 = { local_line = 3, stale = false, confidence = 1.0 },
      },
    }
    package.loaded["parley.services.write"] = {
      open_edit_input = function()
        error("should not edit")
      end,
      delete_comment = function()
        error("should not delete")
      end,
    }

    discussion_window.open_current_line(bufnr)
    assert.is_false(discussion_window.edit_current_comment(bufnr))
    assert.is_false(discussion_window.delete_current_comment(bufnr))
    assert.equals(2, #notify_calls)
  end)

  it("deletes the selected own comment through the write service", function()
    local bufnr = scratch(10)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    local calls = {}

    review_repository._entries[bufnr] = {
      status = "ready",
      stale = false,
      discussions = {
        make_discussion({
          line = 3,
          comments = {
            make_comment({ id = "c1", text = "Delete me", is_own = true }),
          },
        }),
      },
      mappings = {
        d1 = { local_line = 3, stale = false, confidence = 1.0 },
      },
    }
    package.loaded["parley.services.write"] = {
      delete_comment = function(src_bufnr, cursor_line, comment_id)
        calls[#calls + 1] = { bufnr = src_bufnr, cursor_line = cursor_line, comment_id = comment_id }
      end,
    }

    discussion_window.open_current_line(bufnr)
    assert.is_true(discussion_window.delete_current_comment(bufnr))
    assert.same({ { bufnr = bufnr, cursor_line = 3, comment_id = "c1" } }, calls)
  end)

  it("submits through the composer handle instead of the raw window instance", function()
    local bufnr = scratch(10)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    local submitted_text
    local submitted_composer

    review_repository._entries[bufnr] = {
      status = "ready",
      stale = false,
      discussions = { make_discussion({ line = 3, text = "Focused discussion" }) },
      mappings = {
        d1 = { local_line = 3, stale = false, confidence = 1.0 },
      },
    }

    discussion_window.open_current_line(bufnr)
    local composer = discussion_window.show_new_comment_input(bufnr, {
      cursor_line = 3,
      status = "New comment draft",
      on_submit = function(handle, text)
        submitted_composer = handle
        submitted_text = text
        handle.set_submitting("Submitting draft")
      end,
    })
    local instance = discussion_window._instances[bufnr]

    vim.api.nvim_buf_set_lines(instance.input_bufnr, 0, -1, false, { "draft body" })
    instance.submit_input()

    assert.is_true(vim.wait(500, function()
      return submitted_text ~= nil
    end))
    assert.is_true(submitted_composer == composer)
    assert.equals("draft body", submitted_text)
    assert.equals("submitting", instance.input_state)
    assert.same({ "draft body" }, vim.api.nvim_buf_get_lines(instance.input_bufnr, 0, -1, false))
    local marks = vim.api.nvim_buf_get_extmarks(instance.input_bufnr, INPUT_STATUS_NS, 0, -1, { details = true })
    assert.equals(1, #marks)
    assert.same({ { { "Submitting draft", "Comment" } } }, marks[1][4].virt_lines)
  end)

  it("submits the full initial draft text", function()
    local bufnr = scratch(10)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    local submitted_text

    review_repository._entries[bufnr] = {
      status = "ready",
      stale = false,
      discussions = { make_discussion({ line = 3, text = "Focused discussion" }) },
      mappings = {
        d1 = { local_line = 3, stale = false, confidence = 1.0 },
      },
    }

    discussion_window.open_current_line(bufnr)
    local composer = discussion_window.show_new_comment_input(bufnr, {
      cursor_line = 3,
      status = "New comment draft",
      initial_text = "line one\nline two",
      on_submit = function(handle, text)
        submitted_text = text
        handle.set_idle("Draft preserved")
      end,
    })
    local instance = discussion_window._instances[bufnr]

    assert.is_not_nil(composer)
    assert.same({ "line one", "line two" }, vim.api.nvim_buf_get_lines(instance.input_bufnr, 0, -1, false))

    instance.submit_input()

    assert.is_true(vim.wait(500, function()
      return submitted_text ~= nil
    end))
    assert.equals("line one\nline two", submitted_text)
    assert.same({ "line one", "line two" }, vim.api.nvim_buf_get_lines(instance.input_bufnr, 0, -1, false))
    local marks = vim.api.nvim_buf_get_extmarks(instance.input_bufnr, INPUT_STATUS_NS, 0, -1, { details = true })
    assert.equals(1, #marks)
    assert.same({ { { "Draft preserved", "Comment" } } }, marks[1][4].virt_lines)
  end)

  it("keeps the discussion float anchored to the source window after reopening from the float", function()
    local bufnr = scratch(20)
    local source_winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(source_winid, { 3, 0 })

    review_repository._entries[bufnr] = {
      status = "ready",
      stale = false,
      discussions = { make_discussion({ line = 3, text = "Focused discussion" }) },
      mappings = {
        d1 = { local_line = 3, stale = false, confidence = 1.0 },
      },
    }

    discussion_window.open_current_line(bufnr)
    local instance = discussion_window._instances[bufnr]

    vim.api.nvim_set_current_win(instance.winid)
    vim.api.nvim_win_set_cursor(instance.winid, { 2, 0 })
    discussion_window.open_current_line(bufnr, { cursor_line = 3 })

    local cfg = vim.api.nvim_win_get_config(instance.winid)
    local before = vim.api.nvim_win_get_position(instance.winid)

    vim.api.nvim_win_set_cursor(instance.winid, { 3, 0 })
    local after = vim.api.nvim_win_get_position(instance.winid)

    assert.equals("win", cfg.relative)
    assert.equals(source_winid, cfg.win)
    assert.same({ 2, 0 }, cfg.bufpos)
    assert.same(before, after)
  end)

  it("hides the embedded input pane on discard and keeps discussion visible", function()
    local bufnr = scratch(10)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })

    review_repository._entries[bufnr] = {
      status = "ready",
      stale = false,
      discussions = { make_discussion({ line = 3, text = "Focused discussion" }) },
      mappings = {
        d1 = { local_line = 3, stale = false, confidence = 1.0 },
      },
    }

    discussion_window.open_current_line(bufnr)
    discussion_window._confirm_discard = function(_msg)
      return true
    end
    local composer = discussion_window.show_new_comment_input(bufnr, {
      cursor_line = 3,
      status = "New comment draft",
      on_submit = function() end,
    })
    local instance = discussion_window._instances[bufnr]

    vim.api.nvim_buf_set_lines(instance.input_bufnr, 0, -1, false, { "draft body" })
    assert.is_true(composer.close(false))

    assert.is_true(discussion_window.is_open(bufnr))
    assert.is_nil(instance.input_winid)
    assert.is_true(vim.api.nvim_win_is_valid(instance.winid))
  end)
end)
