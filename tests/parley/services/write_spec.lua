--- tests/parley/services/write_spec.lua — Write-side workflows (Step 14)

local mock_provider = require("parley.mock_provider")
local model = require("parley.model")
local read_service = require("parley.services.read")
local write_service = require("parley.services.write")

local SAMPLE_PR = model.new_pr({
  id = "42",
  title = "Add feature",
  state = "open",
  base_branch = "main",
  head_branch = "feature",
  author = "alice",
  url = "https://github.com/owner/repo/pull/42",
  review_status = "pending",
})

local saved = {}

local function save_seams()
  saved.refresh = read_service.refresh
  saved.notify = write_service._notify
  saved.discussion = package.loaded["parley.discussion_window"]
end

local function restore_seams()
  read_service.refresh = saved.refresh
  write_service._notify = saved.notify
  package.loaded["parley.discussion_window"] = saved.discussion
end

local function fake_instance(bufnr)
  local instance = { bufnr = bufnr }
  instance.set_submitting = function(status)
    instance.submitting = status
  end
  instance.set_idle = function(status)
    instance.idle = status
  end
  instance.set_cancel = function(cancel)
    instance.cancel = cancel
  end
  instance.close = function(force)
    instance.closed = force
    return true
  end
  return instance
end

describe("parley.services.write", function()
  local notify_calls

  before_each(function()
    save_seams()
    write_service._operations = {}
    read_service._buffer_state = {}
    notify_calls = {}
    write_service._notify = function(msg, level)
      notify_calls[#notify_calls + 1] = { msg = msg, level = level }
    end
  end)

  after_each(function()
    restore_seams()
    write_service._operations = {}
    read_service._buffer_state = {}
  end)

  it("posts a top-level comment with a normalized range and forces a refresh", function()
    local provider = mock_provider.new({ pr = SAMPLE_PR })
    local refresh_calls = {}
    local opened
    read_service._buffer_state[1] = {
      discussions = {},
      mappings = {},
      pr = SAMPLE_PR,
      head_sha = "deadbeef",
      provider = provider,
      rel_path = "src/foo.lua",
    }

    package.loaded["parley.discussion_window"] = {
      show_new_comment_input = function(_bufnr, opts)
        opened = { opts = opts, instance = fake_instance(99) }
        return opened.instance
      end,
      open_current_line = function() end,
    }
    read_service.refresh = function(bufnr, opts)
      refresh_calls[#refresh_calls + 1] = { bufnr = bufnr, opts = opts }
    end

    write_service.open_new_comment_input(1, { range = 2, line1 = 8, line2 = 5 })
    opened.opts.on_submit(opened.instance, "range draft")

    assert.is_true(vim.wait(500, function()
      return #provider.calls.post_top_level_comment == 1 and #refresh_calls == 1
    end))

    assert.same({ 5, 8 }, provider.calls.post_top_level_comment[1].line)
    assert.same({ bufnr = 1, opts = { force = true, notify_errors = true } }, refresh_calls[1])
    assert.is_true(opened.instance.closed)
    assert.equals("Parley: sending request...", notify_calls[1].msg)
    assert.equals(vim.log.levels.INFO, notify_calls[1].level)
  end)

  it("passes the explicit parent_comment_id to reply", function()
    local root = model.new_comment({
      id = "c1",
      author = "alice",
      body = model.new_body({ text = "root", format = "markdown" }),
      created_at = "2024-01-01T00:00:00Z",
      updated_at = "2024-01-01T00:00:00Z",
    })
    local parent = model.new_comment({
      id = "c2",
      author = "bob",
      body = model.new_body({ text = "parent", format = "markdown" }),
      created_at = "2024-01-01T00:00:01Z",
      updated_at = "2024-01-01T00:00:01Z",
      parent_comment_id = "c1",
    })
    local provider = mock_provider.new({
      pr = SAMPLE_PR,
      discussions = {
        model.new_discussion({
          id = "d1",
          file = "src/foo.lua",
          line = 10,
          comments = { root, parent },
        }),
      },
    })
    local opened
    read_service._buffer_state[1] = {
      discussions = {},
      mappings = {},
      pr = SAMPLE_PR,
      head_sha = "deadbeef",
      provider = provider,
      rel_path = "src/foo.lua",
    }

    package.loaded["parley.discussion_window"] = {
      show_reply_input = function(_bufnr, opts)
        opened = { opts = opts, instance = fake_instance(100) }
        return opened.instance
      end,
      open_current_line = function() end,
    }
    read_service.refresh = function(_bufnr, _opts) end

    write_service.open_reply_input(1, "d1", "c2")
    opened.opts.on_submit(opened.instance, "reply draft")

    assert.is_true(vim.wait(500, function()
      return #provider.calls.reply == 1
    end))

    assert.equals("c2", provider.calls.reply[1].parent_comment_id)
    assert.equals("Parley: sending request...", notify_calls[1].msg)
  end)

  it("does not require VCS detection when opening reply input", function()
    local provider = mock_provider.new({ pr = SAMPLE_PR })
    read_service._buffer_state[1] = {
      discussions = {},
      mappings = {},
      pr = SAMPLE_PR,
      head_sha = "deadbeef",
      provider = provider,
      rel_path = "src/foo.lua",
    }

    package.loaded["parley.discussion_window"] = {
      show_reply_input = function(_bufnr, _opts)
        return fake_instance(101)
      end,
      open_current_line = function() end,
    }

    local ok, err = pcall(function()
      write_service.open_reply_input(1, "d1", "c2")
    end)
    assert.is_true(ok, err)
  end)
end)
