--- tests/parley/init_spec.lua — :Parley command dispatch and completion

local parley = require("parley")
local cache = require("parley.cache")
local read_service = require("parley.services.read")
local registry = require("parley.registry")
local signs = require("parley.signs")
local progress_popup = require("parley.progress_popup")

describe("parley command completion", function()
  it("returns top-level groups for the first argument", function()
    local items = parley._complete_parley("", ":Parley ")
    assert.same({ "discussion", "nav" }, items)
  end)

  it("returns discussion actions for the second argument", function()
    local items = parley._complete_parley("", ":Parley discussion ")
    assert.same({ "open", "close", "toggle", "new", "reply" }, items)
  end)

  it("returns nav actions for the second argument", function()
    local items = parley._complete_parley("", ":Parley nav ")
    assert.same({ "next", "prev" }, items)
  end)
end)

describe("parley setup", function()
  local saved_cache_setup
  local saved_read_refresh_async
  local saved_registry_reset
  local saved_registry_register
  local saved_signs_setup_highlights
  local saved_progress_setup
  local saved_gh

  before_each(function()
    saved_cache_setup = cache.setup
    saved_read_refresh_async = read_service.refresh_async
    saved_registry_reset = registry.reset
    saved_registry_register = registry.register
    saved_signs_setup_highlights = signs.setup_highlights
    saved_progress_setup = progress_popup.setup
    saved_gh = package.loaded["parley.providers.github.provider"]
  end)

  after_each(function()
    cache.setup = saved_cache_setup
    read_service.refresh_async = saved_read_refresh_async
    registry.reset = saved_registry_reset
    registry.register = saved_registry_register
    signs.setup_highlights = saved_signs_setup_highlights
    progress_popup.setup = saved_progress_setup
    package.loaded["parley.providers.github.provider"] = saved_gh
    pcall(vim.api.nvim_del_user_command, "Parley")
    pcall(vim.api.nvim_del_user_command, "ParleyRefresh")
  end)

  it("wires :ParleyRefresh to a progress-enabled refresh", function()
    local calls = {}
    cache.setup = function(_opts) end
    signs.setup_highlights = function() end
    progress_popup.setup = function() end
    registry.reset = function() end
    registry.register = function(_spec) end
    package.loaded["parley.providers.github.provider"] = {
      detect = function()
        return nil
      end,
      new = function()
        return {}
      end,
    }
    read_service.refresh_async = function(bufnr, opts)
      calls[#calls + 1] = { bufnr = bufnr, opts = opts }
    end

    parley.setup({})
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.cmd("ParleyRefresh")

    assert.is_true(#calls >= 1)
    assert.equals(bufnr, calls[#calls].bufnr)
    assert.same({ force = true, progress = true }, calls[#calls].opts)
  end)
end)

describe("parley command dispatch", function()
  local saved_discussion
  local saved_nav
  local saved_write

  before_each(function()
    saved_discussion = package.loaded["parley.discussion_window"]
    saved_nav = package.loaded["parley.nav"]
    saved_write = package.loaded["parley.services.write"]
  end)

  after_each(function()
    package.loaded["parley.discussion_window"] = saved_discussion
    package.loaded["parley.nav"] = saved_nav
    package.loaded["parley.services.write"] = saved_write
  end)

  it("dispatches discussion open/close/toggle/new/reply", function()
    local calls = {}
    package.loaded["parley.discussion_window"] = {
      resolve_source_bufnr = function(bufnr)
        calls[#calls + 1] = { action = "resolve", bufnr = bufnr }
        return bufnr + 100
      end,
      open_current_line = function(bufnr)
        calls[#calls + 1] = { action = "open", bufnr = bufnr }
      end,
      close = function(bufnr)
        calls[#calls + 1] = { action = "close", bufnr = bufnr }
      end,
      toggle_current_line = function(bufnr)
        calls[#calls + 1] = { action = "toggle", bufnr = bufnr }
      end,
      reply_current_line = function(bufnr)
        calls[#calls + 1] = { action = "reply", bufnr = bufnr }
      end,
    }
    package.loaded["parley.services.write"] = {
      open_new_comment_input = function(bufnr, opts)
        calls[#calls + 1] = { action = "new", bufnr = bufnr, opts = opts }
      end,
    }

    parley._dispatch_parley({ "discussion", "open" }, 11)
    parley._dispatch_parley({ "discussion", "close" }, 12)
    parley._dispatch_parley({ "discussion", "toggle" }, 13)
    parley._dispatch_parley({ "discussion", "new" }, 14, { range = 2, line1 = 3, line2 = 5 })
    parley._dispatch_parley({ "discussion", "reply" }, 15)

    assert.same({
      { action = "open", bufnr = 11 },
      { action = "close", bufnr = 12 },
      { action = "toggle", bufnr = 13 },
      { action = "resolve", bufnr = 14 },
      { action = "new", bufnr = 114, opts = { range = 2, line1 = 3, line2 = 5 } },
      { action = "reply", bufnr = 15 },
    }, calls)
  end)

  it("dispatches nav next/prev", function()
    local calls = {}
    package.loaded["parley.nav"] = {
      next = function(bufnr)
        calls[#calls + 1] = { action = "next", bufnr = bufnr }
      end,
      prev = function(bufnr)
        calls[#calls + 1] = { action = "prev", bufnr = bufnr }
      end,
    }

    parley._dispatch_parley({ "nav", "next" }, 21)
    parley._dispatch_parley({ "nav", "prev" }, 22)

    assert.same({
      { action = "next", bufnr = 21 },
      { action = "prev", bufnr = 22 },
    }, calls)
  end)

  it("errors on an unknown group", function()
    assert.has_error(function()
      parley._dispatch_parley({ "nope", "open" }, 1)
    end, "parley: unknown command group: nope")
  end)

  it("errors on an unknown discussion action", function()
    assert.has_error(function()
      parley._dispatch_parley({ "discussion", "nope" }, 1)
    end, "parley: unknown discussion action: nope")
  end)

  it("errors when discussion action is missing", function()
    assert.has_error(function()
      parley._dispatch_parley({ "discussion" }, 1)
    end, "parley: expected a discussion action")
  end)

  it("errors on an unknown nav action", function()
    assert.has_error(function()
      parley._dispatch_parley({ "nav", "nope" }, 1)
    end, "parley: unknown nav action: nope")
  end)

  it("errors when nav action is missing", function()
    assert.has_error(function()
      parley._dispatch_parley({ "nav" }, 1)
    end, "parley: expected a nav action")
  end)
end)
