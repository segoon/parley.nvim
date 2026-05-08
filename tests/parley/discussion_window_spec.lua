--- tests/parley/discussion_window_spec.lua — Discussion window (Step 13)

local discussion_window = require("parley.discussion_window")
local model = require("parley.model")
local composer_ui_state = require("parley.ui_states.composer")
local discussion_ui_state = require("parley.ui_states.discussion")
local read_service = require("parley.services.read")
local review_repository = require("parley.repositories.review")

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
end

local function restore_seams()
  discussion_window._get_config = saved.get_config
  discussion_window._notify = saved.notify
  discussion_window._now = saved.now
  discussion_window._date = saved.date
  discussion_window._strptime = saved.strptime
  discussion_window._confirm_discard = saved.confirm_discard
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

    vim.api.nvim_buf_set_lines(instance.input_bufnr, 1, -1, false, { "draft body" })
    assert.is_true(composer.close(false))

    assert.is_true(discussion_window.is_open(bufnr))
    assert.is_nil(instance.input_winid)
    assert.is_true(vim.api.nvim_win_is_valid(instance.winid))
  end)
end)
