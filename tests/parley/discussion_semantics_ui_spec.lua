local model = require("parley.model")
local entries = require("parley.discussion_entries")
local render = require("parley.discussion_window.render")
local read = require("parley.services.read")

--- @param kind string
--- @param id? string
--- @return parley.Discussion
local function discussion(kind, id)
  return model.new_discussion({
    id = id or "d",
    anchor = { kind = kind, path = kind ~= "general" and "f.lua" or nil, line = kind == "inline" and 3 or nil },
    issue_state = "not_issue",
    comments = {
      model.new_comment({
        id = "c",
        author = "a",
        body = { text = "hello", format = "markdown" },
        created_at = "",
        updated_at = "",
        is_own = true,
      }),
    },
  })
end

describe("review-wide discussion UI", function()
  local saved, buf, state, picker, opened, edits
  before_each(function()
    picker = require("parley.discussion_picker")
    saved = {
      get = read.get_buffer_state,
      list = read.list_discussions,
      refresh = read.refresh_async,
      window = package.loaded["parley.discussion_window"],
      select = picker._select,
      edit = picker._edit,
    }
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    state = {
      pr = { id = "1" },
      vcs_info = { root = "/repo" },
      discussions = {},
      all_discussions = { discussion("general") },
      all_mappings = {},
    }
    read.get_buffer_state = function()
      return state
    end
    read.list_discussions = function()
      return state.all_discussions
    end
    read.refresh_async = function(_, _, callback)
      callback(state)
    end
    opened, edits = {}, {}
    package.loaded["parley.discussion_window"] = {
      resolve_source_bufnr = function(b)
        return b
      end,
      open_discussion = function(b, id)
        opened[#opened + 1] = { b, id }
        return true
      end,
    }
    picker._edit = function(path)
      edits[#edits + 1] = path
    end
    picker._select = function(items, _, callback)
      callback(items[1])
    end
  end)
  after_each(function()
    read.get_buffer_state, read.list_discussions, read.refresh_async = saved.get, saved.list, saved.refresh
    package.loaded["parley.discussion_window"] = saved.window
    picker._select, picker._edit = saved.select, saved.edit
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
  it("opens general discussions without Telescope or changing files", function()
    assert.is_true(picker.open(buf))
    assert.same({ { buf, "d" } }, opened)
    assert.same({}, edits)
    assert.is_nil(entries.location(state.all_discussions[1], "/repo").path)
    assert.matches("general", entries.label(state.all_discussions[1], "/repo"))
  end)
  it("opens historical and whole-file threads without jumping", function()
    for _, kind in ipairs({ "file", "inline" }) do
      local d = discussion(kind)
      d.anchor.unavailable_reason = "Historical diff"
      state.all_discussions = { d }
      picker.open(buf)
      assert.is_nil(entries.location(d, "/repo", {}).line)
    end
    assert.equals(2, #opened)
    assert.same({}, edits)
  end)
  it("keeps issue states and cyclic comments visible", function()
    local d = discussion("general")
    d.comments[1].parent_comment_id = "c"
    local lines, ranges, title = render.render_lines({ d }, {}, {
      format_timestamp = function()
        return "now"
      end,
    })
    assert.is_not_nil(ranges.c)
    assert.is_true(#lines > 0)
    assert.matches("not an issue", title)
  end)
  it("refreshes a real general-discussion float without losing its draft", function()
    package.loaded["parley.discussion_window"] = saved.window
    local window = require("parley.discussion_window")
    local ui = require("parley.ui_states.discussion")
    assert.is_true(window.open_discussion(buf, "d"))
    local instance = window._instances[buf]
    local float = instance.winid
    assert.equals("d", ui.get(buf).current_discussion_id)
    window.show_reply_input(buf, { parent_comment_id = "c", status = "Reply draft", on_submit = function() end })
    vim.api.nvim_buf_set_lines(instance.input_bufnr, 0, -1, false, { "keep this draft" })
    state.all_discussions[1].comments[1].body.text = "updated comment"
    window.refresh_snapshot(buf, state)
    assert.equals(float, instance.winid)
    assert.same({ "keep this draft" }, vim.api.nvim_buf_get_lines(instance.input_bufnr, 0, -1, false))
    assert.is_true(vim.tbl_contains(vim.api.nvim_buf_get_lines(instance.bufnr, 0, -1, false), "  updated comment"))
    assert.equals("d", ui.get(buf).current_discussion_id)
    window.close(buf)
  end)
  it("keeps unavailable file rows invalid and omits general threads from quickfix", function()
    local qf = require("parley.quickfix")
    local set, open = qf._setqflist, qf._copen
    local rows
    qf._setqflist = function(items)
      rows = items
    end
    qf._copen = function() end
    state.all_discussions = { discussion("general"), discussion("file", "file") }
    local ok = qf.open(buf)
    qf._setqflist, qf._copen = set, open
    assert.is_true(ok)
    assert.equals(1, #rows)
    assert.equals(0, rows[1].valid)
    assert.equals(0, rows[1].lnum)
    assert.equals("/repo/f.lua", rows[1].filename)
  end)
  it("adds discussion list command completion", function()
    local parley = require("parley")
    assert.same({ "list" }, parley._complete_parley("li", "Parley discussion li", 20))
  end)
end)
