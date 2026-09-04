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
  saved.check_anchor_in_diff = write_service._check_anchor_in_diff
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
  write_service._check_anchor_in_diff = saved.check_anchor_in_diff
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

describe("parley.services.write — open_new_comment_input sync-state check", function()
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
      return { progress = { success_timeout = 1200, failed_timeout = 2500, cancelled_timeout = 1200 } }
    end
    write_service._check_anchor_in_diff = function()
      return { ok = true }
    end
    write_service._confirm_delete = function()
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

  local function seed_with_provider(provider)
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
  end

  it("notifies and does not open the window when check reports unpushed commits", function()
    local provider = mock_provider.new({ pr = SAMPLE_PR })
    seed_with_provider(provider)
    local window_opened = false
    package.loaded["parley.discussion_window"] = {
      show_new_comment_input = function()
        window_opened = true
      end,
      open_current_line = function() end,
    }
    write_service._check_sync_state = function()
      return {
        ok = false,
        err = "Cannot comment: local branch has commits not yet pushed to the remote. Push first and retry.",
      }
    end

    write_service.open_new_comment_input(1, { line = 5 })

    assert.is_true(vim.wait(300, function()
      return #notify_calls == 1
    end))
    assert.is_false(window_opened)
    assert.is_truthy(notify_calls[1].msg:find("push", 1, true))
    assert.equals(vim.log.levels.WARN, notify_calls[1].level)
  end)

  it("notifies and does not open the window when check reports uncommitted changes", function()
    local provider = mock_provider.new({ pr = SAMPLE_PR })
    seed_with_provider(provider)
    local window_opened = false
    package.loaded["parley.discussion_window"] = {
      show_new_comment_input = function()
        window_opened = true
      end,
      open_current_line = function() end,
    }
    write_service._check_sync_state = function()
      return {
        ok = false,
        err = "Cannot comment: 'src/foo.lua' has uncommitted changes. Commit or stash them and retry.",
      }
    end

    write_service.open_new_comment_input(1, { line = 5 })

    assert.is_true(vim.wait(300, function()
      return #notify_calls == 1
    end))
    assert.is_false(window_opened)
    assert.is_truthy(notify_calls[1].msg:find("uncommitted", 1, true))
    assert.equals(vim.log.levels.WARN, notify_calls[1].level)
  end)

  it("passes root, rel_path, and head_sha to the check", function()
    local provider = mock_provider.new({ pr = SAMPLE_PR })
    seed_with_provider(provider)
    local check_args
    package.loaded["parley.discussion_window"] = {
      show_new_comment_input = function() end,
      open_current_line = function() end,
    }
    write_service._check_sync_state = function(root, rel_path, head_sha)
      check_args = { root = root, rel_path = rel_path, head_sha = head_sha }
      return { ok = true }
    end

    write_service.open_new_comment_input(1, { line = 5 })

    assert.is_true(vim.wait(300, function()
      return check_args ~= nil
    end))
    assert.equals("/repo", check_args.root.root)
    assert.equals("src/foo.lua", check_args.rel_path)
    assert.equals("deadbeef", check_args.head_sha)
  end)
end)

-- ---------------------------------------------------------------------------
-- Suite: open_new_comment_input anchor-in-diff checks
-- ---------------------------------------------------------------------------

describe("parley.services.write — open_new_comment_input anchor-in-diff check", function()
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
      return { progress = { success_timeout = 1200, failed_timeout = 2500, cancelled_timeout = 1200 } }
    end
    write_service._check_sync_state = function()
      return { ok = true }
    end
    write_service._check_anchor_in_diff = function()
      return { ok = true }
    end
    write_service._confirm_delete = function()
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

  local function seed_with_provider(provider)
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
  end

  it("notifies and does not open the window when anchor is not in the PR diff", function()
    local provider = mock_provider.new({ pr = SAMPLE_PR })
    seed_with_provider(provider)
    local window_opened = false
    package.loaded["parley.discussion_window"] = {
      show_new_comment_input = function()
        window_opened = true
      end,
      open_current_line = function() end,
    }
    write_service._check_anchor_in_diff = function()
      return {
        ok = false,
        err = "Cannot comment: line 5 is not part of the PR diff. Move the cursor to a changed line.",
      }
    end

    write_service.open_new_comment_input(1, { line = 5 })

    assert.is_true(vim.wait(300, function()
      return #notify_calls == 1
    end))
    assert.is_false(window_opened)
    assert.is_truthy(notify_calls[1].msg:find("changed line", 1, true))
    assert.equals(vim.log.levels.WARN, notify_calls[1].level)
  end)

  it("does not call check_anchor_in_diff when check_sync_state fails", function()
    local provider = mock_provider.new({ pr = SAMPLE_PR })
    seed_with_provider(provider)
    local diff_check_called = false
    package.loaded["parley.discussion_window"] = {
      show_new_comment_input = function() end,
      open_current_line = function() end,
    }
    write_service._check_sync_state = function()
      return { ok = false, err = "Cannot comment: local branch has commits not yet pushed." }
    end
    write_service._check_anchor_in_diff = function()
      diff_check_called = true
      return { ok = true }
    end

    write_service.open_new_comment_input(1, { line = 5 })

    assert.is_true(vim.wait(300, function()
      return #notify_calls == 1
    end))
    assert.is_false(diff_check_called)
  end)

  it("passes root, base_branch, rel_path, and anchor to check_anchor_in_diff", function()
    local provider = mock_provider.new({ pr = SAMPLE_PR })
    seed_with_provider(provider)
    local diff_check_args
    package.loaded["parley.discussion_window"] = {
      show_new_comment_input = function() end,
      open_current_line = function() end,
    }
    write_service._check_anchor_in_diff = function(root, base_branch, rel_path, anch)
      diff_check_args = { root = root, base_branch = base_branch, rel_path = rel_path, anchor = anch }
      return { ok = true }
    end

    write_service.open_new_comment_input(1, { line = 7 })

    assert.is_true(vim.wait(300, function()
      return diff_check_args ~= nil
    end))
    assert.equals("/repo", diff_check_args.root.root)
    assert.equals("main", diff_check_args.base_branch)
    assert.equals("src/foo.lua", diff_check_args.rel_path)
    assert.equals(7, diff_check_args.anchor.start_line)
  end)

  it("opens the composer when both sync and diff checks pass", function()
    local provider = mock_provider.new({ pr = SAMPLE_PR })
    seed_with_provider(provider)
    local window_opened = false
    package.loaded["parley.discussion_window"] = {
      show_new_comment_input = function()
        window_opened = true
        return fake_instance(1)
      end,
      open_current_line = function() end,
    }

    write_service.open_new_comment_input(1, { line = 5 })

    assert.is_true(vim.wait(300, function()
      return window_opened
    end))
    assert.is_true(window_opened)
  end)
end)
