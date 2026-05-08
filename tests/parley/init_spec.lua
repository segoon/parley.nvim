--- tests/parley/init_spec.lua — :Parley command dispatch and completion

local parley = require("parley")

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
