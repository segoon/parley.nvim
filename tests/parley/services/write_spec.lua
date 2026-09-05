--- tests/parley/services/write_spec.lua — Write-side workflows (Step 14)

local mock_provider = require("parley.mock_provider")
local model = require("parley.model")
local context_repository = require("parley.repositories.context")
local provider_repository = require("parley.repositories.provider")
local review_repository = require("parley.repositories.review")
local read_service = require("parley.services.read")
local write_service = require("parley.services.write")
local progress_ui_state = require("parley.ui_states.progress")

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

local SAMPLE_REVIEW = {
  pr = SAMPLE_PR,
  head_sha = "deadbeef",
  write_context = { number = 42, head_sha = "deadbeef" },
}

local saved = {}

local function save_seams()
  saved.refresh_context = write_service._refresh_context
  write_service._refresh_context = context_repository.get
  vim.bo[1].modified = false
  saved.refresh = read_service.refresh
  saved.review_refresh = review_repository.refresh
  saved.review_invalidate = review_repository.invalidate
  saved.notify = write_service._notify
  saved.defer = write_service._defer
  saved.now = write_service._now
  saved.get_config = write_service._get_config
  saved.confirm_delete = write_service._confirm_delete
  saved.check_sync_state = write_service._check_sync_state
  saved.discussion = package.loaded["parley.discussion_window"]
end

local function restore_seams()
  write_service._refresh_context = saved.refresh_context
  read_service.refresh = saved.refresh
  review_repository.refresh = saved.review_refresh
  review_repository.invalidate = saved.review_invalidate
  write_service._notify = saved.notify
  write_service._defer = saved.defer
  write_service._now = saved.now
  write_service._get_config = saved.get_config
  write_service._confirm_delete = saved.confirm_delete
  write_service._check_sync_state = saved.check_sync_state
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
    context_repository._entries = {}
    provider_repository._entries = {}
    review_repository._reviews = {}
    review_repository._views = {}
    review_repository._bufnr_key = {}
    review_repository._key_bufnrs = {}
    progress_ui_state.clear()
    notify_calls = {}
    write_service._notify = function(msg, level)
      notify_calls[#notify_calls + 1] = { msg = msg, level = level }
    end
    write_service._get_config = function()
      return {
        progress = {
          success_timeout = 1200,
          failed_timeout = 2500,
          cancelled_timeout = 1200,
        },
      }
    end
    write_service._check_sync_state = function()
      return { ok = true }
    end
    write_service._confirm_delete = function(_msg)
      return true
    end
  end)

  after_each(function()
    restore_seams()
    write_service._operations = {}
    context_repository._entries = {}
    provider_repository._entries = {}
    review_repository._reviews = {}
    review_repository._views = {}
    review_repository._bufnr_key = {}
    review_repository._key_bufnrs = {}
    progress_ui_state.clear()
  end)

  local function seed_context(provider, discussions, mappings)
    context_repository._entries[1] = {
      kind = "regular",
      bufnr = 1,
      path = "/repo/src/foo.lua",
      vcs_info = { vcs = "git", root = "/repo", branch = "feature", remote_url = "git@github.com:owner/repo.git" },
      rel_path = "src/foo.lua",
      status = "ready",
    }
    provider_repository._entries[1] = {
      status = "ready",
      provider = provider,
      opts = { repository = "owner/repo", host = "github.com" },
    }
    review_repository._seed(1, {
      status = "ready",
      stale = false,
      review = SAMPLE_REVIEW,
      discussions = discussions or {},
      mappings = mappings or {},
      pr = SAMPLE_PR,
      head_sha = "deadbeef",
    })
  end

  for _, cancellable in ipairs({ true, false }) do
    it(
      "posts a top-level comment with a normalized range and forces a refresh (cancellable="
        .. tostring(cancellable)
        .. ")",
      function()
        local provider = mock_provider.new({ pr = SAMPLE_PR })
        local refresh_calls = {}
        local invalidate_calls = {}
        if not cancellable then
          provider.begin_post_top_level_comment = nil
        end
        local opened
        context_repository._entries[1] = {
          kind = "regular",
          bufnr = 1,
          path = "/repo/src/foo.lua",
          vcs_info = { vcs = "git", root = "/repo", branch = "feature", remote_url = "git@github.com:owner/repo.git" },
          rel_path = "src/foo.lua",
          status = "ready",
        }
        provider_repository._entries[1] = {
          status = "ready",
          provider = provider,
          opts = { repository = "owner/repo", host = "github.com" },
        }
        review_repository._seed(1, {
          status = "ready",
          stale = false,
          review = SAMPLE_REVIEW,
          discussions = {},
          mappings = {},
          pr = SAMPLE_PR,
          head_sha = "deadbeef",
        })

        package.loaded["parley.discussion_window"] = {
          show_new_comment_input = function(_bufnr, opts)
            opened = { opts = opts, instance = fake_instance(99) }
            return opened.instance
          end,
          open_current_line = function() end,
        }
        review_repository.invalidate = function(bufnr, opts)
          invalidate_calls[#invalidate_calls + 1] = { bufnr = bufnr, opts = opts }
        end
        review_repository.refresh = function(bufnr, opts)
          refresh_calls[#refresh_calls + 1] = { bufnr = bufnr, opts = opts }
        end

        write_service.open_new_comment_input(1, { range = 2, line1 = 8, line2 = 5 })
        opened.opts.on_submit(opened.instance, "range draft")

        assert.is_true(vim.wait(500, function()
          return #provider.calls.post_top_level_comment == 1 and #refresh_calls == 1
        end))

        assert.same({ start_line = 5, end_line = 8 }, provider.calls.post_top_level_comment[1].anchor)
        assert.same({ bufnr = 1, opts = { preserve_snapshot = true } }, invalidate_calls[1])
        assert.same({ bufnr = 1, opts = { force = true } }, refresh_calls[1])
        assert.is_true(opened.instance.closed)
        assert.equals(0, #notify_calls)
        local progress_entries = progress_ui_state.list()
        assert.equals(1, #progress_entries)
        assert.equals("success", progress_entries[1].state)
        assert.equals("Comment sent", progress_entries[1].message)
      end
    )
  end

  it("closes the composer before starting the success refresh", function()
    local provider = mock_provider.new({ pr = SAMPLE_PR })
    local opened
    local refresh_saw_closed = false
    local refresh_progress_message
    context_repository._entries[1] = {
      kind = "regular",
      bufnr = 1,
      path = "/repo/src/foo.lua",
      vcs_info = { vcs = "git", root = "/repo", branch = "feature", remote_url = "git@github.com:owner/repo.git" },
      rel_path = "src/foo.lua",
      status = "ready",
    }
    provider_repository._entries[1] = {
      status = "ready",
      provider = provider,
      opts = { repository = "owner/repo", host = "github.com" },
    }
    review_repository._seed(1, {
      status = "ready",
      stale = false,
      review = SAMPLE_REVIEW,
      discussions = {},
      mappings = {},
      pr = SAMPLE_PR,
      head_sha = "deadbeef",
    })

    package.loaded["parley.discussion_window"] = {
      show_new_comment_input = function(_bufnr, opts)
        opened = { opts = opts, instance = fake_instance(99) }
        return opened.instance
      end,
      open_current_line = function() end,
    }
    review_repository.invalidate = function(_bufnr, _opts) end
    review_repository.refresh = function(_bufnr, _opts)
      refresh_saw_closed = opened.instance.closed == true
      local progress_entries = progress_ui_state.list()
      refresh_progress_message = progress_entries[1] and progress_entries[1].message or nil
    end

    write_service.open_new_comment_input(1, { line = 5 })
    opened.opts.on_submit(opened.instance, "draft")

    assert.is_true(vim.wait(500, function()
      return #provider.calls.post_top_level_comment == 1
    end))
    assert.is_true(refresh_saw_closed)
    assert.equals("Refreshing discussion", refresh_progress_message)
    assert.is_true(opened.instance.closed)
  end)

  for _, cancellable in ipairs({ true, false }) do
    it("passes the explicit parent_comment_id to reply (cancellable=" .. tostring(cancellable) .. ")", function()
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
      if not cancellable then
        provider.begin_reply = nil
      end
      local opened
      context_repository._entries[1] = {
        kind = "regular",
        bufnr = 1,
        path = "/repo/src/foo.lua",
        vcs_info = { vcs = "git", root = "/repo", branch = "feature", remote_url = "git@github.com:owner/repo.git" },
        rel_path = "src/foo.lua",
        status = "ready",
      }
      provider_repository._entries[1] = {
        status = "ready",
        provider = provider,
        opts = { repository = "owner/repo", host = "github.com" },
      }
      review_repository._seed(1, {
        status = "ready",
        stale = false,
        review = SAMPLE_REVIEW,
        discussions = {},
        mappings = {},
        pr = SAMPLE_PR,
        head_sha = "deadbeef",
      })

      package.loaded["parley.discussion_window"] = {
        show_reply_input = function(_bufnr, opts)
          opened = { opts = opts, instance = fake_instance(100) }
          return opened.instance
        end,
        open_current_line = function() end,
      }
      review_repository.invalidate = function(_bufnr) end
      review_repository.refresh = function(_bufnr, _opts) end

      write_service.open_reply_input(1, provider.state.discussions[1], provider.state.discussions[1].comments[2])
      opened.opts.on_submit(opened.instance, "reply draft")

      assert.is_true(vim.wait(500, function()
        return #provider.calls.reply == 1 and progress_ui_state.list()[1].state == "success"
      end))

      assert.equals("c2", provider.calls.reply[1].parent_comment.id)
      local progress_entries = progress_ui_state.list()
      assert.equals(1, #progress_entries)
      assert.equals("success", progress_entries[1].state)
      assert.equals("Reply sent", progress_entries[1].message)
    end)
  end

  it("does not require VCS detection when opening reply input", function()
    local provider = mock_provider.new({ pr = SAMPLE_PR })
    context_repository._entries[1] = {
      kind = "regular",
      bufnr = 1,
      path = "/repo/src/foo.lua",
      vcs_info = { vcs = "git", root = "/repo", branch = "feature", remote_url = "git@github.com:owner/repo.git" },
      rel_path = "src/foo.lua",
      status = "ready",
    }
    provider_repository._entries[1] = {
      status = "ready",
      provider = provider,
      opts = { repository = "owner/repo", host = "github.com" },
    }
    review_repository._seed(1, {
      status = "ready",
      stale = false,
      review = SAMPLE_REVIEW,
      discussions = {},
      mappings = {},
      pr = SAMPLE_PR,
      head_sha = "deadbeef",
    })

    package.loaded["parley.discussion_window"] = {
      show_reply_input = function(_bufnr, _opts)
        return fake_instance(101)
      end,
      open_current_line = function() end,
    }

    local ok, err = pcall(function()
      write_service.open_reply_input(
        1,
        model.new_discussion({ id = "d1", file = "src/foo.lua", line = 10, comments = {} }),
        {
          id = "c2",
          author = "bob",
          body = model.new_body({ text = "parent", format = "markdown" }),
          created_at = "2024-01-01T00:00:01Z",
          updated_at = "2024-01-01T00:00:01Z",
        }
      )
    end)
    assert.is_true(ok, err)
  end)

  it("rejects direct reactions without an offered choice", function()
    local provider = mock_provider.new({ pr = SAMPLE_PR })
    seed_context(provider)
    local comment = model.new_comment({
      id = "c",
      author = "a",
      body = model.new_body({ text = "x", format = "markdown" }),
      created_at = "",
      updated_at = "",
    })
    assert.is_false(write_service.react_comment(1, 10, comment, "unknown"))
    assert.equals(0, #provider.calls.react)
    provider.reaction_choices = function()
      return { { reaction = "valid", label = "Valid" } }
    end
    assert.is_false(write_service.react_comment(1, 10, comment, "unknown"))
    assert.equals(0, #provider.calls.react)
  end)

  it("reacts to a comment and refreshes the discussion", function()
    local comment = model.new_comment({
      id = "c1",
      author = "alice",
      body = model.new_body({ text = "root", format = "markdown" }),
      created_at = "2024-01-01T00:00:00Z",
      updated_at = "2024-01-01T00:00:00Z",
      reactions = {},
    })
    local provider = mock_provider.new({
      pr = SAMPLE_PR,
      discussions = {
        model.new_discussion({ id = "d1", file = "src/foo.lua", line = 10, comments = { comment } }),
      },
    })
    local refresh_calls = {}
    local invalidate_calls = {}
    package.loaded["parley.discussion_window"] = {
      open_current_line = function() end,
    }
    provider.reaction_choices = function()
      return { { reaction = "+1", label = "Like" } }
    end
    seed_context(provider)
    review_repository.invalidate = function(bufnr, opts)
      invalidate_calls[#invalidate_calls + 1] = { bufnr = bufnr, opts = opts }
    end
    review_repository.refresh = function(bufnr, opts)
      refresh_calls[#refresh_calls + 1] = { bufnr = bufnr, opts = opts }
    end

    write_service.react_comment(1, 10, comment, "+1")

    assert.is_true(vim.wait(500, function()
      return #provider.calls.react == 1 and #refresh_calls == 1
    end))
    assert.equals("c1", provider.calls.react[1].comment_id)
    assert.equals("+1", provider.calls.react[1].reaction)
    assert.same({ bufnr = 1, opts = { preserve_snapshot = true } }, invalidate_calls[1])
    assert.same({ bufnr = 1, opts = { force = true } }, refresh_calls[1])
  end)

  it("opens edit input prefilled with the current comment body and submits edits", function()
    local comment = model.new_comment({
      id = "c1",
      author = "alice",
      body = model.new_body({ text = "old body", format = "markdown" }),
      created_at = "2024-01-01T00:00:00Z",
      updated_at = "2024-01-01T00:00:00Z",
      is_own = true,
    })
    local provider = mock_provider.new({
      pr = SAMPLE_PR,
      discussions = {
        model.new_discussion({ id = "d1", file = "src/foo.lua", line = 10, comments = { comment } }),
      },
    })
    local opened
    seed_context(provider, {
      model.new_discussion({ id = "d1", file = "src/foo.lua", line = 10, comments = { comment } }),
    }, {
      d1 = { local_line = 10, stale = false, confidence = 1.0 },
    })
    package.loaded["parley.discussion_window"] = {
      show_reply_input = function(_bufnr, opts)
        opened = { opts = opts, instance = fake_instance(101) }
        return opened.instance
      end,
      open_current_line = function() end,
    }
    review_repository.invalidate = function(_bufnr, _opts) end
    review_repository.refresh = function(_bufnr, _opts) end

    write_service.open_edit_input(1, provider.state.discussions[1], provider.state.discussions[1].comments[1])
    assert.equals("old body", opened.opts.initial_text)
    opened.opts.on_submit(opened.instance, "new body")

    assert.is_true(vim.wait(500, function()
      return #provider.calls.edit == 1
    end))
    assert.equals("c1", provider.calls.edit[1].comment_id)
    assert.equals("new body", provider.calls.edit[1].body.text)
  end)

  it("asks for delete confirmation before deleting a comment", function()
    local comment = model.new_comment({
      id = "c1",
      author = "alice",
      body = model.new_body({ text = "root", format = "markdown" }),
      created_at = "2024-01-01T00:00:00Z",
      updated_at = "2024-01-01T00:00:00Z",
      is_own = true,
    })
    local provider = mock_provider.new({
      pr = SAMPLE_PR,
      discussions = {
        model.new_discussion({ id = "d1", file = "src/foo.lua", line = 10, comments = { comment } }),
      },
    })
    local confirmed = {}
    package.loaded["parley.discussion_window"] = {
      open_current_line = function() end,
    }
    seed_context(provider)
    write_service._confirm_delete = function(msg)
      confirmed[#confirmed + 1] = msg
      return true
    end
    review_repository.invalidate = function(_bufnr, _opts) end
    review_repository.refresh = function(_bufnr, _opts) end

    write_service.delete_comment(1, 10, comment)

    assert.is_true(vim.wait(500, function()
      return #provider.calls.delete == 1
    end))
    assert.equals(1, #confirmed)
    assert.equals("c1", provider.calls.delete[1].comment_id)
  end)

  it("does not delete when the user cancels confirmation", function()
    local comment = model.new_comment({
      id = "c1",
      author = "alice",
      body = model.new_body({ text = "root", format = "markdown" }),
      created_at = "2024-01-01T00:00:00Z",
      updated_at = "2024-01-01T00:00:00Z",
      is_own = true,
    })
    local provider = mock_provider.new({
      pr = SAMPLE_PR,
      discussions = {
        model.new_discussion({ id = "d1", file = "src/foo.lua", line = 10, comments = { comment } }),
      },
    })
    package.loaded["parley.discussion_window"] = {
      open_current_line = function() end,
    }
    seed_context(provider)
    write_service._confirm_delete = function(_msg)
      return false
    end

    local ok = write_service.delete_comment(1, 10, comment)

    assert.is_false(ok)
    assert.equals(0, #provider.calls.delete)
  end)
end)

-- ---------------------------------------------------------------------------
-- Suite: open_new_comment_input sync-state checks
-- ---------------------------------------------------------------------------
