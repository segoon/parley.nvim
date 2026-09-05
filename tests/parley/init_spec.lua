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
    assert.same({ "discussion", "comment", "nav", "quickfix", "refresh" }, items)
  end)

  it("returns discussion actions for the second argument", function()
    local items = parley._complete_parley("", ":Parley discussion ")
    assert.same({ "open", "close", "toggle", "new", "reply", "list", "resolve", "reopen" }, items)
  end)

  it("returns comment actions for the second argument", function()
    local items = parley._complete_parley("", ":Parley comment ")
    assert.same({ "react", "edit", "delete" }, items)
  end)

  it("returns nav actions for the second argument", function()
    local items = parley._complete_parley("", ":Parley nav ")
    assert.same({ "buf-next", "buf-prev", "review-next", "review-prev" }, items)
  end)
end)

describe("parley setup", function()
  local saved_cache_setup
  local saved_read_refresh_async
  local saved_registry_reset
  local saved_registry_register
  local saved_signs_setup_highlights
  local saved_progress_setup
  local saved_notify
  local saved_gh
  local saved_telescope

  before_each(function()
    require("parley.vcs").reset_adapters()
    require("parley.vcs").reset_detectors()
    saved_cache_setup = cache.setup
    saved_read_refresh_async = read_service.refresh_async
    saved_registry_reset = registry.reset
    saved_registry_register = registry.register
    saved_signs_setup_highlights = signs.setup_highlights
    saved_progress_setup = progress_popup.setup
    saved_notify = parley._notify
    saved_gh = package.loaded["parley.providers.github.provider"]
    saved_telescope = package.loaded["telescope"]
  end)

  after_each(function()
    require("parley.vcs").reset_adapters()
    require("parley.vcs").reset_detectors()
    cache.setup = saved_cache_setup
    read_service.refresh_async = saved_read_refresh_async
    registry.reset = saved_registry_reset
    registry.register = saved_registry_register
    signs.setup_highlights = saved_signs_setup_highlights
    progress_popup.setup = saved_progress_setup
    parley._notify = saved_notify
    package.loaded["parley.providers.github.provider"] = saved_gh
    package.loaded["telescope"] = saved_telescope
    pcall(vim.api.nvim_del_user_command, "Parley")
  end)

  it("resets and registers VCS adapters on repeated setup", function()
    local vcs = require("parley.vcs")
    local adapters = require("parley.vcs.adapters")
    cache.setup = function() end
    signs.setup_highlights = function() end
    progress_popup.setup = function() end
    read_service.refresh_async = function() end
    parley.setup({ telescope = false })
    vcs.register_adapter("temporary", require("parley.providers.vcs.git"))
    parley.setup({ telescope = false })
    assert.is_nil(adapters.get({ vcs = "temporary", root = "/checkout" }))
    assert.is_not_nil(adapters.get({ vcs = "git", root = "/checkout" }))
    assert.is_not_nil(adapters.get({ vcs = "arc", root = "/checkout" }))
    assert.equals(2, #vcs.registered_detectors())
  end)

  it("snapshots provider settings across repeated setup", function()
    local specs = {}
    cache.setup = function() end
    signs.setup_highlights = function() end
    progress_popup.setup = function() end
    read_service.refresh_async = function() end
    registry.register = function(spec)
      specs[#specs + 1] = spec
    end
    local opts = { telescope = false, providers = { arcanum = { host = "first.example", retry_count = 0 } } }
    parley.setup(opts)
    local factory = specs[2].factory
    local auth = {
      read_token = function()
        return "token"
      end,
    }
    local p = factory({ _auth = auth })
    opts.providers.arcanum.host = "mutated.example"
    parley.config.providers.arcanum.host = "mutated.example"
    assert.equals("first.example", p._host)
    assert.equals("first.example", factory({ _auth = auth })._host)
    assert.equals(0, require("parley.providers.arcanum.transport").transport_config(p).retry_count)
    parley.setup({ telescope = false, providers = { arcanum = { host = "second.example" } } })
    assert.equals("second.example", specs[4].factory({ _auth = auth })._host)
    assert.equals("first.example", p._host)
    parley.setup({ telescope = false })
    assert.equals("arcanum.yandex.net", specs[6].factory({ _auth = auth })._host)
  end)

  it("wires :Parley refresh to a progress-enabled refresh", function()
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
    vim.cmd("Parley refresh")

    assert.is_true(#calls >= 1)
    assert.equals(bufnr, calls[#calls].bufnr)
    assert.same({ force = true, progress = true }, calls[#calls].opts)
  end)

  it("exposes the public statusline wrapper", function()
    local saved_statusline = package.loaded["parley.statusline"]
    package.loaded["parley.statusline"] = {
      component = function(bufnr)
        return "status-" .. tostring(bufnr)
      end,
    }

    local ok, result = pcall(function()
      return parley.statusline(12)
    end)

    package.loaded["parley.statusline"] = saved_statusline

    assert.is_true(ok)
    assert.equals("status-12", result)
  end)

  it("loads Parley Telescope extensions by default", function()
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
    package.loaded["telescope"] = {
      load_extension = function(name)
        calls[#calls + 1] = name
      end,
    }

    parley.setup({})

    assert.same({ "parley_discussions", "parley_discussions_file" }, calls)
    assert.is_true(parley.config.telescope)
  end)

  it("skips Telescope autoload when telescope=false", function()
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
    package.loaded["telescope"] = {
      load_extension = function(name)
        calls[#calls + 1] = name
      end,
    }

    parley.setup({ telescope = false })

    assert.same({}, calls)
    assert.is_false(parley.config.telescope)
  end)

  it("warns when telescope=true and telescope.nvim is not installed", function()
    local notifications = {}
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
    parley._notify = function(msg, level)
      notifications[#notifications + 1] = { msg = msg, level = level }
    end
    package.loaded["telescope"] = nil

    parley.setup({ telescope = true })

    assert.same({
      { msg = "parley: telescope.nvim is not installed", level = vim.log.levels.WARN },
    }, notifications)
  end)
end)

describe("parley command dispatch", function()
  local saved_discussion
  local saved_nav
  local saved_quickfix
  local saved_write

  before_each(function()
    saved_discussion = package.loaded["parley.discussion_window"]
    saved_nav = package.loaded["parley.nav"]
    saved_quickfix = package.loaded["parley.quickfix"]
    saved_write = package.loaded["parley.services.write"]
  end)

  after_each(function()
    package.loaded["parley.discussion_window"] = saved_discussion
    package.loaded["parley.nav"] = saved_nav
    package.loaded["parley.quickfix"] = saved_quickfix
    package.loaded["parley.services.write"] = saved_write
  end)

  it("dispatches discussion and comment actions", function()
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
      react_current_comment = function(bufnr)
        calls[#calls + 1] = { action = "react", bufnr = bufnr }
      end,
      edit_current_comment = function(bufnr)
        calls[#calls + 1] = { action = "edit", bufnr = bufnr }
      end,
      delete_current_comment = function(bufnr)
        calls[#calls + 1] = { action = "delete", bufnr = bufnr }
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
    parley._dispatch_parley({ "comment", "react" }, 16)
    parley._dispatch_parley({ "comment", "edit" }, 17)
    parley._dispatch_parley({ "comment", "delete" }, 18)

    assert.same({
      { action = "open", bufnr = 11 },
      { action = "close", bufnr = 12 },
      { action = "toggle", bufnr = 13 },
      { action = "resolve", bufnr = 14 },
      { action = "new", bufnr = 114, opts = { range = 2, line1 = 3, line2 = 5 } },
      { action = "reply", bufnr = 15 },
      { action = "react", bufnr = 16 },
      { action = "edit", bufnr = 17 },
      { action = "delete", bufnr = 18 },
    }, calls)
  end)

  it("dispatches nav buf-next/buf-prev/review-next/review-prev", function()
    local calls = {}
    package.loaded["parley.nav"] = {
      buf_next = function(bufnr)
        calls[#calls + 1] = { action = "buf-next", bufnr = bufnr }
      end,
      buf_prev = function(bufnr)
        calls[#calls + 1] = { action = "buf-prev", bufnr = bufnr }
      end,
      review_next = function(bufnr)
        calls[#calls + 1] = { action = "review-next", bufnr = bufnr }
      end,
      review_prev = function(bufnr)
        calls[#calls + 1] = { action = "review-prev", bufnr = bufnr }
      end,
    }

    parley._dispatch_parley({ "nav", "buf-next" }, 21)
    parley._dispatch_parley({ "nav", "buf-prev" }, 22)
    parley._dispatch_parley({ "nav", "review-next" }, 23)
    parley._dispatch_parley({ "nav", "review-prev" }, 24)

    assert.same({
      { action = "buf-next", bufnr = 21 },
      { action = "buf-prev", bufnr = 22 },
      { action = "review-next", bufnr = 23 },
      { action = "review-prev", bufnr = 24 },
    }, calls)
  end)

  it("dispatches quickfix without subcommands", function()
    local calls = {}
    package.loaded["parley.quickfix"] = {
      open = function(bufnr)
        calls[#calls + 1] = bufnr
      end,
    }

    parley._dispatch_parley({ "quickfix" }, 31)

    assert.same({ 31 }, calls)
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

  it("errors on an unknown comment action", function()
    assert.has_error(function()
      parley._dispatch_parley({ "comment", "nope" }, 1)
    end, "parley: unknown comment action: nope")
  end)

  it("errors when comment action is missing", function()
    assert.has_error(function()
      parley._dispatch_parley({ "comment" }, 1)
    end, "parley: expected a comment action")
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

  it("errors when quickfix has a subcommand", function()
    assert.has_error(function()
      parley._dispatch_parley({ "quickfix", "nope" }, 1)
    end, "parley: quickfix does not accept subcommands")
  end)
end)
