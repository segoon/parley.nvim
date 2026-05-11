--- tests/parley/quickfix_spec.lua — quickfix population.

local model = require("parley.model")

--- @param id string
--- @param file string
--- @param line integer
--- @param text string
--- @return parley.Discussion
local function make_discussion(id, file, line, text)
  return model.new_discussion({
    id = id,
    file = file,
    line = line,
    resolved = false,
    comments = {
      model.new_comment({
        id = id .. "-c1",
        author = "alice",
        body = model.new_body({ text = text, format = "markdown" }),
        created_at = "2024-01-01T10:00:00Z",
        updated_at = "2024-01-01T10:00:00Z",
      }),
    },
  })
end

describe("parley.quickfix", function()
  local saved = {}

  before_each(function()
    saved.quickfix = package.loaded["parley.quickfix"]
    saved.read = package.loaded["parley.services.read"]
    package.loaded["parley.quickfix"] = nil
    vim.fn.setqflist({}, "r")
  end)

  after_each(function()
    package.loaded["parley.quickfix"] = saved.quickfix
    package.loaded["parley.services.read"] = saved.read
    vim.fn.setqflist({}, "r")
  end)

  it("populates quickfix from review-wide discussions using all_mappings", function()
    local calls = {}
    package.loaded["parley.services.read"] = {
      get_buffer_state = function(_bufnr)
        return {
          pr = { id = "42" },
          vcs_info = { root = "/repo" },
          all_discussions = {
            make_discussion("d1", "src/foo.lua", 10, "first comment"),
            make_discussion("d2", "src/bar.lua", 20, "second comment"),
          },
          all_mappings = {
            d1 = { local_line = 12, stale = false, confidence = 1.0 },
            d2 = { local_line = 25, stale = false, confidence = 1.0 },
          },
        }
      end,
    }

    local quickfix = require("parley.quickfix")
    quickfix._setqflist = function(items, action, opts)
      calls[#calls + 1] = { kind = "setqflist", items = items, action = action, opts = opts }
    end
    quickfix._copen = function()
      calls[#calls + 1] = { kind = "copen" }
    end

    assert.is_true(quickfix.open(1))
    assert.equals("setqflist", calls[1].kind)
    assert.equals("r", calls[1].action)
    assert.equals("Parley Discussions", calls[1].opts.title)
    assert.same({
      {
        filename = "/repo/src/foo.lua",
        lnum = 12,
        col = 1,
        text = "[unresolved] alice: first comment",
      },
      {
        filename = "/repo/src/bar.lua",
        lnum = 25,
        col = 1,
        text = "[unresolved] alice: second comment",
      },
    }, calls[1].items)
    assert.equals("copen", calls[2].kind)
  end)

  it("falls back to discussion.line when no review-wide mapping exists", function()
    local captured = nil
    package.loaded["parley.services.read"] = {
      get_buffer_state = function(_bufnr)
        return {
          pr = { id = "42" },
          vcs_info = { root = "/repo" },
          all_discussions = {
            make_discussion("d1", "src/foo.lua", 10, "first comment"),
          },
          all_mappings = {},
        }
      end,
    }

    local quickfix = require("parley.quickfix")
    quickfix._setqflist = function(items, _action, _opts)
      captured = items
    end
    quickfix._copen = function() end

    assert.is_true(quickfix.open(1))
    assert.equals(10, captured[1].lnum)
  end)

  it("writes the real quickfix list and reads it back", function()
    package.loaded["parley.services.read"] = {
      get_buffer_state = function(_bufnr)
        return {
          pr = { id = "42" },
          vcs_info = { root = "/repo" },
          all_discussions = {
            make_discussion("d1", "src/foo.lua", 10, "first comment"),
            make_discussion("d2", "src/bar.lua", 20, "second comment"),
          },
          all_mappings = {
            d1 = { local_line = 12, stale = false, confidence = 1.0 },
            d2 = { local_line = 25, stale = false, confidence = 1.0 },
          },
        }
      end,
    }

    local quickfix = require("parley.quickfix")
    quickfix._copen = function() end

    assert.is_true(quickfix.open(1))

    local qf = vim.fn.getqflist({ title = 1, items = 1 })
    assert.equals("Parley Discussions", qf.title)
    assert.equals(2, #qf.items)
    assert.equals(12, qf.items[1].lnum)
    assert.equals(25, qf.items[2].lnum)
    assert.equals(1, qf.items[1].col)
    assert.is_truthy(qf.items[1].text:find("first comment", 1, true))
    assert.is_truthy(qf.items[2].text:find("second comment", 1, true))
  end)

  it("skips discussions whose mapped local line was deleted", function()
    package.loaded["parley.services.read"] = {
      get_buffer_state = function(_bufnr)
        return {
          pr = { id = "42" },
          vcs_info = { root = "/repo" },
          all_discussions = {
            make_discussion("d1", "src/foo.lua", 10, "deleted comment"),
            make_discussion("d2", "src/bar.lua", 20, "kept comment"),
          },
          all_mappings = {
            d1 = { local_line = nil, stale = true, confidence = 0.0 },
            d2 = { local_line = 25, stale = false, confidence = 1.0 },
          },
        }
      end,
    }

    local quickfix = require("parley.quickfix")
    quickfix._copen = function() end

    assert.is_true(quickfix.open(1))

    local qf = vim.fn.getqflist({ title = 1, items = 1 })
    assert.equals("Parley Discussions", qf.title)
    assert.equals(2, #qf.items)
    assert.equals(10, qf.items[1].lnum)
    assert.equals(25, qf.items[2].lnum)
  end)

  it("notifies when there is no active review", function()
    local notifications = {}
    package.loaded["parley.services.read"] = {
      get_buffer_state = function(_bufnr)
        return nil
      end,
    }

    local quickfix = require("parley.quickfix")
    quickfix._notify = function(msg, level)
      notifications[#notifications + 1] = { msg = msg, level = level }
    end

    assert.is_false(quickfix.open(1))
    assert.same({
      { msg = "parley: no active PR discussions for this buffer", level = vim.log.levels.INFO },
    }, notifications)
  end)

  it("notifies when the active review has no discussions", function()
    local notifications = {}
    package.loaded["parley.services.read"] = {
      get_buffer_state = function(_bufnr)
        return {
          pr = { id = "42" },
          vcs_info = { root = "/repo" },
          all_discussions = {},
          all_mappings = {},
        }
      end,
    }

    local quickfix = require("parley.quickfix")
    quickfix._notify = function(msg, level)
      notifications[#notifications + 1] = { msg = msg, level = level }
    end

    assert.is_false(quickfix.open(1))
    assert.same({
      { msg = "parley: no discussions in the active review", level = vim.log.levels.INFO },
    }, notifications)
  end)
end)
