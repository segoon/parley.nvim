--- tests/parley/init_spec.lua — :Parley command dispatch and completion

local parley = require("parley")

describe("parley command completion", function()
  it("returns top-level groups for the first argument", function()
    local items = parley._complete_parley("", ":Parley ")
    assert.same({ "discussion", "nav" }, items)
  end)

  it("returns discussion actions for the second argument", function()
    local items = parley._complete_parley("", ":Parley discussion ")
    assert.same({ "open", "close", "toggle" }, items)
  end)

  it("returns nav actions for the second argument", function()
    local items = parley._complete_parley("", ":Parley nav ")
    assert.same({ "next", "prev" }, items)
  end)
end)

describe("parley command dispatch", function()
  local saved_discussion
  local saved_nav

  before_each(function()
    saved_discussion = package.loaded["parley.discussion_window"]
    saved_nav = package.loaded["parley.nav"]
  end)

  after_each(function()
    package.loaded["parley.discussion_window"] = saved_discussion
    package.loaded["parley.nav"] = saved_nav
  end)

  it("dispatches discussion open/close/toggle", function()
    local calls = {}
    package.loaded["parley.discussion_window"] = {
      open_current_line = function(bufnr)
        calls[#calls + 1] = { action = "open", bufnr = bufnr }
      end,
      close = function(bufnr)
        calls[#calls + 1] = { action = "close", bufnr = bufnr }
      end,
      toggle_current_line = function(bufnr)
        calls[#calls + 1] = { action = "toggle", bufnr = bufnr }
      end,
    }

    parley._dispatch_parley({ "discussion", "open" }, 11)
    parley._dispatch_parley({ "discussion", "close" }, 12)
    parley._dispatch_parley({ "discussion", "toggle" }, 13)

    assert.same({
      { action = "open", bufnr = 11 },
      { action = "close", bufnr = 12 },
      { action = "toggle", bufnr = 13 },
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

  it("errors on an unknown nav action", function()
    assert.has_error(function()
      parley._dispatch_parley({ "nav", "nope" }, 1)
    end, "parley: unknown nav action: nope")
  end)
end)
