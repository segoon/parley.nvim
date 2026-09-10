--- tests/parley/hover_spec.lua — cursor-driven hover previews.
---
--- Strategy: seed review_repository state for a scratch buffer/window (same
--- convention as discussion_window_spec.lua), stub hover._get_config to
--- control which hover flags are active, stub hover._defer_fn to run
--- synchronously (capturing the requested delay) instead of scheduling a
--- real libuv timer, and drive hover._on_cursor_moved directly (it reads the
--- real cursor position via the Neovim API, so we move the cursor with
--- nvim_win_set_cursor first).

local hover = require("parley.hover")
local signs = require("parley.signs")
local discussion_window = require("parley.discussion_window")
local model = require("parley.model")
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
--- @return parley.Discussion
local function make_discussion(opts)
  opts = opts or {}
  return model.new_discussion({
    id = opts.id or "d1",
    file = opts.file or "src/foo.lua",
    line = opts.line or 3,
    comments = opts.comments or {
      model.new_comment({
        id = "c1",
        author = "alice",
        body = model.new_body({ text = opts.text or "Hello", format = "markdown" }),
        created_at = "2024-01-01T10:00:00Z",
        updated_at = "2024-01-01T10:00:00Z",
      }),
    },
  })
end

local function base_config()
  return {
    signs = { enabled = true, text = "▐" },
    virtual_text = { enabled = true, max_width = 60, hover = false },
    floating_text = {
      hover = false,
      hover_delay = 0.5,
      border = "rounded",
      max_width = 60,
      max_height = 12,
      width_ratio = 0.6,
      height_ratio = 0.4,
    },
  }
end

local saved = {}
local render_calls
--- Timer stub: records scheduled calls and lets tests fire/cancel them
--- without a real delay.
local deferred

local function save_seams()
  saved.get_config = hover._get_config
  saved.defer_fn = hover._defer_fn
  saved.render = signs.render
  saved.is_open = discussion_window.is_open
end

local function restore_seams()
  hover._get_config = saved.get_config
  hover._defer_fn = saved.defer_fn
  signs.render = saved.render
  discussion_window.is_open = saved.is_open
end

--- Run the most recently scheduled deferred callback, if any.
local function fire_hover_timer()
  local entry = deferred[#deferred]
  assert(entry and not entry.cancelled, "no pending hover timer to fire")
  entry.fn()
end

describe("parley.hover", function()
  before_each(function()
    save_seams()
    render_calls = {}
    deferred = {}
    signs.render = function(...)
      render_calls[#render_calls + 1] = { ... }
    end
    hover._defer_fn = function(fn, delay_ms)
      local entry = { fn = fn, delay_ms = delay_ms, cancelled = false }
      deferred[#deferred + 1] = entry
      return {
        stop = function()
          entry.cancelled = true
        end,
        close = function() end,
      }
    end
    hover._last_line = {}
    hover._timers = {}
    for bufnr in pairs(hover._floats) do
      hover._close_float(bufnr)
    end
    for bufnr in pairs(review_repository._bufnr_key) do
      read_service.clear_buffer_state(bufnr)
    end
    review_repository._reviews = {}
    review_repository._views = {}
    review_repository._bufnr_key = {}
    review_repository._key_bufnrs = {}
  end)

  after_each(function()
    for bufnr in pairs(hover._floats) do
      hover._close_float(bufnr)
    end
    restore_seams()
  end)

  describe("virtual_text.hover", function()
    it("does nothing when virtual_text.hover and floating_text.hover are both off", function()
      local bufnr = scratch(10)
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      review_repository._seed(bufnr, {
        status = "ready",
        discussions = { make_discussion({ line = 3 }) },
        mappings = { d1 = { local_line = 3, stale = false, confidence = 1.0 } },
      })
      hover._get_config = base_config

      hover._on_cursor_moved()

      assert.equal(0, #render_calls)
      assert.is_nil(hover._floats[bufnr])
      assert.equal(0, #deferred)
    end)

    it("calls signs.render with the cursor line when virtual_text.hover is on", function()
      local bufnr = scratch(10)
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      review_repository._seed(bufnr, {
        status = "ready",
        discussions = { make_discussion({ line = 3 }) },
        mappings = { d1 = { local_line = 3, stale = false, confidence = 1.0 } },
      })
      local config = base_config()
      config.virtual_text.hover = true
      hover._get_config = function()
        return config
      end

      hover._on_cursor_moved()

      assert.equal(1, #render_calls)
      local call = render_calls[1]
      assert.equal(bufnr, call[1])
      assert.equal(3, call[5])
    end)

    it("skips re-rendering when the cursor stays on the same line", function()
      local bufnr = scratch(10)
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      review_repository._seed(bufnr, {
        status = "ready",
        discussions = { make_discussion({ line = 3 }) },
        mappings = { d1 = { local_line = 3, stale = false, confidence = 1.0 } },
      })
      local config = base_config()
      config.virtual_text.hover = true
      hover._get_config = function()
        return config
      end

      hover._on_cursor_moved()
      hover._on_cursor_moved()

      assert.equal(1, #render_calls)
    end)
  end)

  describe("floating_text.hover", function()
    it("schedules a timer using floating_text.hover_delay (in ms) instead of opening immediately", function()
      local bufnr = scratch(10)
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      review_repository._seed(bufnr, {
        status = "ready",
        discussions = { make_discussion({ line = 3 }) },
        mappings = { d1 = { local_line = 3, stale = false, confidence = 1.0 } },
      })
      local config = base_config()
      config.floating_text.hover = true
      config.floating_text.hover_delay = 0.75
      hover._get_config = function()
        return config
      end
      discussion_window.is_open = function()
        return false
      end

      hover._on_cursor_moved()

      assert.equal(1, #deferred)
      assert.equal(750, deferred[1].delay_ms)
      assert.is_nil(hover._floats[bufnr]) -- not opened yet; timer hasn't fired
    end)

    it("opens an unfocused preview float once the hover-delay timer fires", function()
      local bufnr = scratch(10)
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      review_repository._seed(bufnr, {
        status = "ready",
        discussions = { make_discussion({ line = 3, text = "Look at this" }) },
        mappings = { d1 = { local_line = 3, stale = false, confidence = 1.0 } },
      })
      local config = base_config()
      config.floating_text.hover = true
      hover._get_config = function()
        return config
      end
      discussion_window.is_open = function()
        return false
      end

      hover._on_cursor_moved()
      fire_hover_timer()

      local float = hover._floats[bufnr]
      assert.is_not_nil(float)
      assert.is_true(vim.api.nvim_win_is_valid(float.winid))
      local win_cfg = vim.api.nvim_win_get_config(float.winid)
      assert.is_false(win_cfg.focusable)
      local lines = vim.api.nvim_buf_get_lines(float.bufnr, 0, -1, false)
      assert.is_not_nil(vim.tbl_contains(lines, "Look at this"))
    end)

    it("cancels the pending timer when the cursor leaves the line before it fires", function()
      local bufnr = scratch(10)
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      review_repository._seed(bufnr, {
        status = "ready",
        discussions = { make_discussion({ line = 3 }) },
        mappings = { d1 = { local_line = 3, stale = false, confidence = 1.0 } },
      })
      local config = base_config()
      config.floating_text.hover = true
      hover._get_config = function()
        return config
      end
      discussion_window.is_open = function()
        return false
      end

      hover._on_cursor_moved()
      assert.equal(1, #deferred)

      vim.api.nvim_win_set_cursor(0, { 7, 0 })
      hover._on_cursor_moved()

      assert.is_true(deferred[1].cancelled)
      assert.is_nil(hover._floats[bufnr])
    end)

    it("closes a live preview float once the cursor leaves the discussion range", function()
      local bufnr = scratch(10)
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      review_repository._seed(bufnr, {
        status = "ready",
        discussions = { make_discussion({ line = 3 }) },
        mappings = { d1 = { local_line = 3, stale = false, confidence = 1.0 } },
      })
      local config = base_config()
      config.floating_text.hover = true
      hover._get_config = function()
        return config
      end
      discussion_window.is_open = function()
        return false
      end

      hover._on_cursor_moved()
      fire_hover_timer()
      assert.is_not_nil(hover._floats[bufnr])

      vim.api.nvim_win_set_cursor(0, { 7, 0 })
      hover._on_cursor_moved()

      assert.is_nil(hover._floats[bufnr])
    end)

    it("does not open the float if the cursor moved off the line by the time the timer fires", function()
      local bufnr = scratch(10)
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      review_repository._seed(bufnr, {
        status = "ready",
        discussions = { make_discussion({ line = 3 }) },
        mappings = { d1 = { local_line = 3, stale = false, confidence = 1.0 } },
      })
      local config = base_config()
      config.floating_text.hover = true
      hover._get_config = function()
        return config
      end
      discussion_window.is_open = function()
        return false
      end

      hover._on_cursor_moved()
      local pending = deferred[1]
      -- Simulate the cursor moving away without going through
      -- _on_cursor_moved again (e.g. a stale timer captured before this
      -- assertion runs in a real event loop).
      vim.api.nvim_win_set_cursor(0, { 7, 0 })
      pending.fn()

      assert.is_nil(hover._floats[bufnr])
    end)

    it("does nothing when the interactive discussion window is already open", function()
      local bufnr = scratch(10)
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      review_repository._seed(bufnr, {
        status = "ready",
        discussions = { make_discussion({ line = 3 }) },
        mappings = { d1 = { local_line = 3, stale = false, confidence = 1.0 } },
      })
      local config = base_config()
      config.floating_text.hover = true
      hover._get_config = function()
        return config
      end
      discussion_window.is_open = function()
        return true
      end

      hover._on_cursor_moved()
      fire_hover_timer()

      assert.is_nil(hover._floats[bufnr])
    end)

    it("does not schedule a timer when the cursor is not on a discussion line", function()
      local bufnr = scratch(10)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      review_repository._seed(bufnr, {
        status = "ready",
        discussions = { make_discussion({ line = 3 }) },
        mappings = { d1 = { local_line = 3, stale = false, confidence = 1.0 } },
      })
      local config = base_config()
      config.floating_text.hover = true
      hover._get_config = function()
        return config
      end
      discussion_window.is_open = function()
        return false
      end

      hover._on_cursor_moved()

      assert.equal(0, #deferred)
      assert.is_nil(hover._floats[bufnr])
    end)
  end)
end)

describe("discussion_window.make_win_config focusable default", function()
  it("still opens the interactive discussion window as focusable by default", function()
    local window_helpers = require("parley.discussion_window.window")
    local bufnr = scratch(5)
    local source_winid = vim.api.nvim_get_current_win()
    local float_cfg = { border = "rounded", max_width = 80, max_height = 30, width_ratio = 0.8, height_ratio = 0.8 }

    local config = window_helpers.make_win_config({}, float_cfg, source_winid, 1, nil)

    assert.is_true(config.focusable)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
end)
