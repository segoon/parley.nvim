--- tests/parley/discussion_window_spec.lua — Discussion window (Step 13)

local discussion_window = require("parley.discussion_window")
local model = require("parley.model")
local orchestrator = require("parley.orchestrator")

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
end

local function restore_seams()
  discussion_window._get_config = saved.get_config
  discussion_window._notify = saved.notify
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
    for bufnr in pairs(discussion_window._instances) do
      discussion_window.close(bufnr)
    end
    for bufnr in pairs(orchestrator._buffer_state) do
      orchestrator.clear_buffer_state(bufnr)
    end
  end)

  after_each(function()
    for bufnr in pairs(discussion_window._instances) do
      discussion_window.close(bufnr)
    end
    for bufnr in pairs(orchestrator._buffer_state) do
      orchestrator.clear_buffer_state(bufnr)
    end
    restore_seams()
  end)

  it("opens a window for discussions on the current line", function()
    local bufnr = scratch(10)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })

    orchestrator._buffer_state[bufnr] = {
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

    local lines = vim.api.nvim_buf_get_lines(instance.bufnr, 0, -1, false)
    assert.is_not_nil(vim.tbl_contains(lines, "## Thread 1 · unresolved"))
    assert.is_not_nil(vim.tbl_contains(lines, "Review this nil guard"))
  end)

  it("notifies and stays closed when the current line has no discussions", function()
    local bufnr = scratch(10)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    orchestrator._buffer_state[bufnr] = {
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
    vim.api.nvim_win_set_cursor(0, { 3, 0 })

    orchestrator._buffer_state[bufnr] = {
      discussions = { make_discussion({ line = 3 }) },
      mappings = {
        d1 = { local_line = 3, stale = false, confidence = 1.0 },
      },
    }

    assert.is_true(discussion_window.toggle_current_line(bufnr))
    assert.is_true(discussion_window.is_open(bufnr))

    assert.is_false(discussion_window.toggle_current_line(bufnr))
    assert.is_false(discussion_window.is_open(bufnr))
  end)

  it("renders nested replies using parent_comment_id indentation", function()
    local bufnr = scratch(10)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })

    orchestrator._buffer_state[bufnr] = {
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

    assert.is_not_nil(vim.tbl_contains(lines, "- **alice** · 2024-01-01T10:00:00Z"))
    assert.is_not_nil(vim.tbl_contains(lines, "  - **bob** · 2024-01-01T10:00:00Z"))
    assert.is_not_nil(vim.tbl_contains(lines, "    Reply comment"))
  end)

  it("updates the window content when reopened on a different line", function()
    local bufnr = scratch(10)

    orchestrator._buffer_state[bufnr] = {
      discussions = {
        make_discussion({ id = "d1", line = 3, text = "First line discussion" }),
        make_discussion({ id = "d2", line = 6, text = "Second line discussion" }),
      },
      mappings = {
        d1 = { local_line = 3, stale = false, confidence = 1.0 },
        d2 = { local_line = 6, stale = false, confidence = 1.0 },
      },
    }

    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    discussion_window.open_current_line(bufnr)
    local first_winid = discussion_window._instances[bufnr].winid

    vim.api.nvim_win_set_cursor(0, { 6, 0 })
    discussion_window.open_current_line(bufnr)

    local instance = discussion_window._instances[bufnr]
    local lines = vim.api.nvim_buf_get_lines(instance.bufnr, 0, -1, false)
    assert.is_true(vim.api.nvim_win_is_valid(instance.winid))
    assert.is_not_nil(vim.tbl_contains(lines, "Second line discussion"))
    assert.equal(first_winid, instance.winid)
  end)
end)
