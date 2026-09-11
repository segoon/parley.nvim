local browser = require("parley.browser")
local read = require("parley.services.read")
local ui = require("parley.ui_states.discussion")

describe("browser actions", function()
  local saved_get
  local saved_window
  local saved_open
  local saved_notify
  local state
  local selected
  local selected_comment
  local choose
  local opened
  local notifications

  before_each(function()
    saved_get = read.get_buffer_state
    saved_window = package.loaded["parley.discussion_window"]
    saved_open = browser._open
    saved_notify = browser._notify
    state = {
      pr = { id = "42", url = "https://example.test/review/42" },
      all_discussions = {},
    }
    selected = nil
    selected_comment = nil
    choose = nil
    opened = {}
    notifications = {}
    read.get_buffer_state = function()
      return state
    end
    package.loaded["parley.discussion_window"] = {
      resolve_source_bufnr = function()
        return 7
      end,
      current_discussion = function()
        return selected
      end,
      current_comment = function()
        return selected_comment
      end,
      open_current_line = function(_, opts)
        choose = opts.on_select
        return true
      end,
    }
    browser._open = function(url)
      opened[#opened + 1] = url
      return {}
    end
    browser._notify = function(message, level)
      notifications[#notifications + 1] = { message = message, level = level }
    end
  end)

  after_each(function()
    ui.clear(7)
    read.get_buffer_state = saved_get
    package.loaded["parley.discussion_window"] = saved_window
    browser._open = saved_open
    browser._notify = saved_notify
  end)

  it("opens the active review from a Parley float", function()
    assert.is_true(browser.open_review(99))
    assert.same({ "https://example.test/review/42" }, opened)
  end)

  it("reports when there is no active review", function()
    state = nil
    assert.is_false(browser.open_review(7))
    assert.same({
      { message = "parley: no active review for this buffer", level = vim.log.levels.INFO },
    }, notifications)
  end)

  it("reports a missing review link", function()
    state.pr.url = ""
    assert.is_false(browser.open_review(7))
    assert.same({
      { message = "parley: review link is unavailable", level = vim.log.levels.INFO },
    }, notifications)
  end)

  it("opens the selected discussion from a Parley float", function()
    selected = { id = "root", url = "https://example.test/review/42#root" }
    assert.is_true(browser.open_discussion(99))
    assert.same({ "https://example.test/review/42#root" }, opened)
    assert.is_nil(choose)
  end)

  it("uses the current-line chooser when no discussion is selected", function()
    state.all_discussions = { { id = "root", url = "https://example.test/review/42#root" } }
    assert.is_true(browser.open_discussion(7))
    assert.same({}, opened)
    assert.is_true(choose(state.all_discussions[1]))
    assert.same({ "https://example.test/review/42#root" }, opened)
  end)

  it("does not replace a disappeared selected discussion with a line target", function()
    ui.set(7, { current_discussion_id = "removed" })
    assert.is_false(browser.open_discussion(7))
    assert.is_nil(choose)
    assert.same({
      {
        message = "Selected discussion is no longer available; refresh the review",
        level = vim.log.levels.INFO,
      },
    }, notifications)
  end)

  it("rejects a picker selection after the active review changes", function()
    state.all_discussions = { { id = "root", url = "https://example.test/review/42#root" } }
    assert.is_true(browser.open_discussion(7))
    state = { pr = { id = "43", url = "https://example.test/review/43" }, all_discussions = {} }
    assert.is_false(choose({ id = "root", url = "https://example.test/review/42#root" }))
    assert.same({}, opened)
    assert.same({
      { message = "Parley review changed; choose the discussion again", level = vim.log.levels.INFO },
    }, notifications)
  end)

  it("reports when an exact discussion link is unavailable", function()
    selected = { id = "root" }
    assert.is_false(browser.open_discussion(7))
    assert.same({}, opened)
    assert.same({
      { message = "parley: discussion link is unavailable", level = vim.log.levels.INFO },
    }, notifications)
  end)

  it("reports failures from the system URL handler", function()
    browser._open = function()
      return nil, "no handler"
    end
    assert.is_false(browser.open_review(7))
    assert.same({
      { message = "parley: could not open review: no handler", level = vim.log.levels.WARN },
    }, notifications)
  end)

  it("opens the selected comment from a Parley float", function()
    selected_comment = { id = "reply", url = "https://example.test/review/42#reply" }
    assert.is_true(browser.open_comment(99))
    assert.same({ "https://example.test/review/42#reply" }, opened)
  end)

  it("requires a selected comment", function()
    assert.is_false(browser.open_comment(7))
    assert.same({
      { message = "parley: select a comment before opening it in the browser", level = vim.log.levels.INFO },
    }, notifications)
  end)

  it("reports a missing exact comment link", function()
    selected_comment = { id = "reply" }
    assert.is_false(browser.open_comment(7))
    assert.same({
      { message = "parley: comment link is unavailable", level = vim.log.levels.INFO },
    }, notifications)
  end)
end)
