--- Tests for parley.services.read — end-to-end refresh orchestration.
--- Run via: make test
---
--- Every external dependency is replaced with an in-memory or recording
--- double:
---   • buffer_context._get_buf_props / _vcs_detect — fixed buffer kind
---   • registry — a single mock-provider spec
---   • parley.anchor._runner — empty diff (identity mapping)
---   • parley.signs.render / .clear — recorders
---   • parley.cache._fs — in-memory dictionary
---   • read_service._notify / _get_config — recorders / fixed config
---   • async_operation._defer / _get_config — prevent real timers in tests
---
--- No real filesystem, network, or git invocations.

local anchor = require("parley.anchor")
local async_operation = require("parley.async_operation")
local buffer_context = require("parley.buffer_context")
local cache = require("parley.cache")
local mock_provider = require("parley.mock_provider")
local model = require("parley.model")
local context_repository = require("parley.repositories.context")
local provider_repository = require("parley.repositories.provider")
local review_repository = require("parley.repositories.review")
local read_service = require("parley.services.read")
local registry = require("parley.registry")
local signs = require("parley.signs")
local progress_ui_state = require("parley.ui_states.progress")

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

local SAMPLE_VCS = {
  vcs = "git",
  root = "/repo",
  branch = "feature",
  remote_url = "git@github.com:owner/repo.git",
}

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

---@param pr parley.PR
---@return parley.DetectedReview
local function make_review(pr)
  return {
    pr = pr,
    head_sha = "deadbeef",
    write_context = { number = tonumber(pr.id), head_sha = "deadbeef" },
  }
end

local function make_discussion(id, file, line, text)
  return model.new_discussion({
    id = tostring(id),
    file = file,
    line = line,
    resolved = false,
    comments = {
      model.new_comment({
        id = tostring(id),
        author = "alice",
        body = model.new_body({ text = text, format = "markdown" }),
        created_at = "2024-01-01T10:00:00Z",
        updated_at = "2024-01-01T10:00:00Z",
      }),
    },
  })
end

local SAMPLE_CONFIG = {
  signs = { enabled = true, text = "▐" },
  virtual_text = { enabled = true, max_width = 60 },
}

-- ---------------------------------------------------------------------------
-- Test scaffolding
-- ---------------------------------------------------------------------------

--- Build a fake in-memory FS backend for parley.cache.
local function make_fake_fs()
  local files = {}
  return {
    _files = files,
    read = function(path)
      return files[path]
    end,
    write = function(path, content)
      files[path] = content
    end,
    delete = function(path)
      -- Delete this exact key plus any "subdirectory" entries.
      for k in pairs(files) do
        if k == path or k:sub(1, #path + 1) == path .. "/" then
          files[k] = nil
        end
      end
    end,
    mkdir = function(_path) end,
  }
end

--- Saved originals for after_each restoration.
local saved = {}

local function save_seams()
  saved.buf_props = buffer_context._get_buf_props
  saved.vcs_detect = buffer_context._vcs_detect
  saved.anchor_runner = anchor._runner
  saved.signs_render = signs.render
  saved.signs_clear = signs.clear
  saved.cache_fs = cache._fs
  saved.notify = read_service._notify
  saved.get_config = read_service._get_config
  saved.async_op_defer = async_operation._defer
  saved.async_op_config = async_operation._get_config
end

local function restore_seams()
  buffer_context._get_buf_props = saved.buf_props
  buffer_context._vcs_detect = saved.vcs_detect
  anchor._runner = saved.anchor_runner
  signs.render = saved.signs_render
  signs.clear = saved.signs_clear
  cache._fs = saved.cache_fs
  read_service._notify = saved.notify
  read_service._get_config = saved.get_config
  async_operation._defer = saved.async_op_defer
  async_operation._get_config = saved.async_op_config
end

--- Wire seams for a test.
---
--- @param o {
---   path?: string,           -- buffer name
---   filetype?: string,
---   buftype?: string,
---   vcs_info?: parley.VcsInfo|nil,
---   pr?: parley.PR|nil,
---   discussions?: parley.Discussion[],
---   provider_error?: { method: string, msg: string },
---   no_provider?: boolean,
---   config?: table,
--- }
--- @return { provider: table, render_calls: table[], clear_calls: integer[],
---           notify_calls: { msg: string, level: integer }[], fs: table }
local function setup(o)
  o = o or {}

  -- Buffer classification: regular file inside the repo.
  buffer_context._get_buf_props = function(_bufnr)
    return {
      filetype = o.filetype or "",
      name = o.path or "/repo/src/foo.lua",
      buftype = o.buftype or "",
    }
  end
  buffer_context._vcs_detect = function(_path)
    if o.vcs_info == nil then
      return SAMPLE_VCS
    end
    if o.vcs_info == false then
      return nil
    end
    return o.vcs_info
  end

  -- Anchor: empty diff → identity mapping (local_line == pr_line, not stale).
  anchor._runner = function(_cmd, _cwd)
    return { code = 0, stdout = "", stderr = "" }
  end

  -- Signs recorders.
  local render_calls = {}
  signs.render = function(bufnr, discussions, mappings, opts)
    table.insert(render_calls, {
      bufnr = bufnr,
      discussions = discussions,
      mappings = mappings,
      opts = opts,
    })
  end
  local clear_calls = {}
  signs.clear = function(bufnr)
    table.insert(clear_calls, bufnr)
  end

  -- Cache: in-memory FS.
  local fake_fs = make_fake_fs()
  cache._fs = fake_fs
  cache.setup({ cache_dir = "/cache" })

  -- Notify recorder.
  local notify_calls = {}
  read_service._notify = function(msg, level)
    table.insert(notify_calls, { msg = msg, level = level })
  end

  -- Config.
  read_service._get_config = function()
    return o.config or SAMPLE_CONFIG
  end

  -- Prevent async_operation defer from removing progress entries mid-test.
  async_operation._defer = function(_cb, _timeout) end
  async_operation._get_config = function()
    return { progress = { success_timeout = 2500, failed_timeout = 2500 } }
  end

  -- Reentrancy guard: clear any state from previous tests.
  review_repository._reviews = {}
  review_repository._views = {}
  review_repository._bufnr_key = {}
  review_repository._key_bufnrs = {}
  review_repository._in_flight = {}
  review_repository._pending_force = {}
  review_repository._subscribers = {}
  context_repository._entries = {}
  provider_repository._entries = {}
  read_service._subscriptions = {}

  -- Provider via the registry.
  registry.reset()
  local provider = nil
  if not o.no_provider then
    provider = mock_provider.new({
      pr = o.pr,
      head_sha = "deadbeef",
      write_context = o.pr and { number = tonumber(o.pr.id), head_sha = "deadbeef" } or nil,
      discussions = o.discussions or {},
    })
    if o.provider_error then
      provider:set_error(o.provider_error.method, o.provider_error.msg)
    end
    registry.register({
      name = "MockGitHub",
      detect = function(_vcs)
        return { host = "github.com", repository = "owner/repo" }
      end,
      factory = function(_opts)
        return provider
      end,
    })
  end

  return {
    provider = provider,
    render_calls = render_calls,
    clear_calls = clear_calls,
    notify_calls = notify_calls,
    fs = fake_fs,
  }
end

-- ---------------------------------------------------------------------------
-- Suites
-- ---------------------------------------------------------------------------

describe("parley.services.read refresh", function()
  before_each(function()
    save_seams()
    progress_ui_state.clear()
  end)

  after_each(function()
    vim.wait(20, function()
      return false
    end)
    restore_seams()
    registry.reset()
    progress_ui_state.clear()
  end)

  -- -------------------------------------------------------------------------
  -- 1. Happy path
  -- -------------------------------------------------------------------------

  it("renders signs for the current file's discussions only", function()
    local s = setup({
      path = "/repo/src/foo.lua",
      pr = SAMPLE_PR,
      discussions = {
        make_discussion(1, "src/foo.lua", 10, "for foo"),
        make_discussion(2, "src/foo.lua", 20, "also foo"),
        make_discussion(3, "src/bar.lua", 5, "for bar"),
      },
    })

    read_service.refresh_async(1)
    assert.is_true(vim.wait(200, function()
      return #s.render_calls >= 1
    end))

    assert.equals(1, #s.render_calls, "expected exactly one render call")
    local rc = s.render_calls[1]
    assert.equals(1, rc.bufnr)
    assert.equals(2, #rc.discussions, "should filter out src/bar.lua discussion")
    assert.equals("src/foo.lua", rc.discussions[1].file)
    assert.equals("src/foo.lua", rc.discussions[2].file)

    local state = read_service.get_buffer_state(1)
    assert.is_not_nil(state)
    assert.equals(2, #state.discussions)
    assert.equals(10, state.mappings["1"].local_line)
  end)

  it("lists discussions for the current file or the whole PR", function()
    setup({
      path = "/repo/src/foo.lua",
      pr = SAMPLE_PR,
      discussions = {
        make_discussion(1, "src/foo.lua", 10, "for foo"),
        make_discussion(2, "src/foo.lua", 20, "also foo"),
        make_discussion(3, "src/bar.lua", 5, "for bar"),
      },
    })

    read_service.refresh_async(1)
    assert.is_true(vim.wait(200, function()
      return #read_service.list_discussions(1) >= 2
    end))

    local file_discussions = read_service.list_discussions(1)
    local all_discussions = read_service.list_discussions(1, { scope = "all" })

    assert.equals(2, #file_discussions)
    assert.equals("1", file_discussions[1].id)
    assert.equals("2", file_discussions[2].id)
    assert.equals(3, #all_discussions)
    assert.equals("1", all_discussions[1].id)
    assert.equals("2", all_discussions[2].id)
    assert.equals("3", all_discussions[3].id)
  end)

  it("calls detect_pr and fetch_discussions on the provider", function()
    local s = setup({ pr = SAMPLE_PR, discussions = {} })

    read_service.refresh_async(1)
    assert.is_true(vim.wait(200, function()
      return #s.provider.calls.detect_pr >= 1
    end))

    assert.equals(1, #s.provider.calls.detect_pr)
    assert.equals(1, #s.provider.calls.fetch_discussions)
    assert.equals("feature", s.provider.calls.detect_pr[1].branch)
    assert.equals("/repo", s.provider.calls.detect_pr[1].repo_root)
  end)

  -- -------------------------------------------------------------------------
  -- 2. No PR detected
  -- -------------------------------------------------------------------------

  it("clears signs when detect_pr returns nil (no PR for branch)", function()
    local s = setup({ pr = nil })

    review_repository._seed(1, {
      status = "ready",
      stale = false,
      discussions = { make_discussion(99, "src/foo.lua", 5, "stale") },
      mappings = { ["99"] = { local_line = 5, stale = false, confidence = 1.0 } },
    })

    read_service.refresh_async(1)
    assert.is_true(vim.wait(200, function()
      return #s.provider.calls.detect_pr >= 1
    end))

    assert.equals(0, #s.render_calls)
    assert.is_true(#s.clear_calls >= 1)
    assert.equals(1, s.clear_calls[#s.clear_calls])
    assert.is_nil(read_service.get_buffer_state(1))
  end)

  it("removes the cached PR record when detect_pr returns nil", function()
    local s = setup({ pr = nil })

    -- Pre-seed the cache with a stale PR record so we can verify it goes away.
    cache.set(
      { provider = "github", repository = "owner/repo", subkey = "pr_branch_feature" },
      { review = make_review(SAMPLE_PR) }
    )
    assert.is_not_nil(
      cache.get({ provider = "github", repository = "owner/repo", subkey = "pr_branch_feature" }),
      "precondition: cache should hold the seeded entry"
    )

    read_service.refresh_async(1)
    assert.is_true(vim.wait(200, function()
      return #s.provider.calls.detect_pr >= 1
    end))

    local entry = cache.get({ provider = "github", repository = "owner/repo", subkey = "pr_branch_feature" })
    assert.is_nil(entry)
    -- Suppress unused warning.
    assert.is_table(s.fs._files)
  end)

  -- -------------------------------------------------------------------------
  -- 3 & 4. Stale-while-revalidate behaviour
  -- -------------------------------------------------------------------------

  it("renders cached data first, then fresh data, when force=false", function()
    local s = setup({
      pr = SAMPLE_PR,
      discussions = { make_discussion(1, "src/foo.lua", 10, "fresh") },
    })

    -- Pre-seed cache (after setup so the in-memory fs is in place).
    cache.set(
      { provider = "github", repository = "owner/repo", subkey = "pr_branch_feature" },
      { review = make_review(SAMPLE_PR) }
    )
    cache.set(
      { provider = "github", repository = "owner/repo", subkey = "discussions_42" },
      { make_discussion(99, "src/foo.lua", 5, "stale") }
    )

    read_service.refresh_async(1)
    assert.is_true(vim.wait(200, function()
      return #s.render_calls >= 2
    end))

    -- Expect 2 renders: stale (id 99) then fresh (id 1).
    assert.equals(2, #s.render_calls)
    assert.equals("99", s.render_calls[1].discussions[1].id)
    assert.equals("1", s.render_calls[2].discussions[1].id)
  end)

  it("skips the stale render when force=true", function()
    local s = setup({
      pr = SAMPLE_PR,
      discussions = { make_discussion(1, "src/foo.lua", 10, "fresh") },
    })

    cache.set(
      { provider = "github", repository = "owner/repo", subkey = "pr_branch_feature" },
      { review = make_review(SAMPLE_PR) }
    )
    cache.set(
      { provider = "github", repository = "owner/repo", subkey = "discussions_42" },
      { make_discussion(99, "src/foo.lua", 5, "stale") }
    )

    read_service.refresh_async(1, { force = true })
    assert.is_true(vim.wait(200, function()
      return #s.render_calls >= 1
    end))

    assert.equals(1, #s.render_calls)
    assert.equals("1", s.render_calls[1].discussions[1].id)
  end)

  it("preserves rendered decorations when only cached review data is invalidated", function()
    local s = setup({
      pr = SAMPLE_PR,
      discussions = { make_discussion(1, "src/foo.lua", 10, "fresh") },
    })

    read_service.refresh_async(1)
    assert.is_true(vim.wait(200, function()
      return #s.render_calls >= 1
    end))
    local clear_count = #s.clear_calls

    review_repository.invalidate(1, { preserve_snapshot = true })

    assert.is_not_nil(read_service.get_buffer_state(1))
    assert.equals(clear_count, #s.clear_calls)
    assert.equals(1, #s.render_calls)
  end)

  it("publishes progress for explicit refresh requests", function()
    setup({
      pr = SAMPLE_PR,
      discussions = { make_discussion(1, "src/foo.lua", 10, "fresh") },
    })

    read_service.refresh_async(1, { force = true, progress = true })
    assert.is_true(vim.wait(200, function()
      local entries = progress_ui_state.list()
      return #entries >= 1 and entries[1].state == "success"
    end))

    local progress_entries = progress_ui_state.list()
    assert.equals(1, #progress_entries)
    assert.equals("operation", progress_entries[1].kind)
    assert.equals("success", progress_entries[1].state)
    assert.equals("Refresh complete", progress_entries[1].message)
  end)

  -- -------------------------------------------------------------------------
  -- 5. Error path
  -- -------------------------------------------------------------------------

  it("notifies and leaves stale render in place when fetch raises", function()
    local s = setup({
      pr = SAMPLE_PR,
      discussions = {},
      provider_error = { method = "fetch_discussions", msg = "network down" },
    })

    -- Pre-seed cache so the stale render runs first (after setup so fake fs is in place).
    cache.set(
      { provider = "github", repository = "owner/repo", subkey = "pr_branch_feature" },
      { review = make_review(SAMPLE_PR) }
    )
    cache.set(
      { provider = "github", repository = "owner/repo", subkey = "discussions_42" },
      { make_discussion(99, "src/foo.lua", 5, "stale") }
    )

    read_service.refresh_async(1)
    assert.is_true(vim.wait(200, function()
      return #s.notify_calls >= 1
    end))

    -- Stale render happened.
    assert.equals(1, #s.render_calls)
    assert.equals("99", s.render_calls[1].discussions[1].id)
    -- And we got a warn-level notify.
    assert.equals(1, #s.notify_calls)
    assert.equals(vim.log.levels.WARN, s.notify_calls[1].level)
    assert.is_not_nil(s.notify_calls[1].msg:find("parley"))
    assert.equals("99", read_service.get_buffer_state(1).discussions[1].id)
  end)

  it("stays silent for background refresh failures when notify_errors=false", function()
    local s = setup({
      pr = SAMPLE_PR,
      discussions = {},
      provider_error = { method = "fetch_discussions", msg = "network down" },
    })

    cache.set(
      { provider = "github", repository = "owner/repo", subkey = "pr_branch_feature" },
      { review = make_review(SAMPLE_PR) }
    )
    cache.set(
      { provider = "github", repository = "owner/repo", subkey = "discussions_42" },
      { make_discussion(99, "src/foo.lua", 5, "stale") }
    )

    read_service.refresh_async(1, { notify_errors = false })
    assert.is_true(vim.wait(200, function()
      return #s.render_calls >= 1
    end))

    assert.equals(1, #s.render_calls)
    assert.equals(0, #s.notify_calls)
    assert.equals("99", read_service.get_buffer_state(1).discussions[1].id)
  end)

  it("keeps PR state and clears decorations when the current file has no discussions", function()
    local s = setup({
      path = "/repo/src/foo.lua",
      pr = SAMPLE_PR,
      discussions = { make_discussion(1, "src/bar.lua", 10, "for bar") },
    })

    review_repository._seed(1, {
      status = "ready",
      stale = false,
      discussions = { make_discussion(99, "src/foo.lua", 5, "stale") },
      mappings = { ["99"] = { local_line = 5, stale = false, confidence = 1.0 } },
    })

    read_service.refresh_async(1)
    assert.is_true(vim.wait(200, function()
      return #s.clear_calls >= 1
    end))

    assert.equals(1, #s.clear_calls)
    local state = read_service.get_buffer_state(1)
    assert.is_not_nil(state)
    assert.equals("42", state.pr.id)
    assert.equals(0, #state.discussions)
    assert.equals(1, state.summary.unresolved_count)
  end)

  -- -------------------------------------------------------------------------
  -- 6. Reentrancy
  -- -------------------------------------------------------------------------

  it("returns immediately when a refresh is already in flight for this bufnr", function()
    local s = setup({ pr = SAMPLE_PR, discussions = {} })

    -- Simulate an in-flight call (keyed by review_key, not bufnr).
    local rk = "github/owner/repo/feature"
    review_repository._in_flight[rk] = true

    read_service.refresh_async(1)
    vim.wait(100, function()
      return false
    end)

    assert.equals(0, #s.provider.calls.detect_pr)
    assert.equals(0, #s.render_calls)

    review_repository._in_flight[rk] = nil
  end)

  it("queues a forced rerun when force=true arrives during an in-flight refresh", function()
    local s = setup({ pr = SAMPLE_PR, discussions = {} })

    local rk = "github/owner/repo/feature"
    review_repository._in_flight[rk] = true

    read_service.refresh_async(1, { force = true })
    vim.wait(100, function()
      return false
    end)

    assert.is_true(review_repository._pending_force[rk])
    assert.equals(0, #s.provider.calls.detect_pr)

    review_repository._in_flight[rk] = nil
    review_repository._pending_force[rk] = nil
  end)

  -- -------------------------------------------------------------------------
  -- 7. Non-regular buffers are silently skipped
  -- -------------------------------------------------------------------------

  it("does nothing for a diffview buffer", function()
    local s = setup({
      filetype = "DiffviewFiles",
      pr = SAMPLE_PR,
    })

    read_service.refresh_async(1)
    vim.wait(50, function()
      return false
    end)

    assert.equals(0, #s.render_calls)
    assert.equals(0, #s.clear_calls)
    assert.equals(0, #s.provider.calls.detect_pr)
  end)

  it("does nothing for a non-VCS buffer", function()
    local s = setup({
      vcs_info = false,
      pr = SAMPLE_PR,
    })

    read_service.refresh_async(1)
    vim.wait(50, function()
      return false
    end)

    assert.equals(0, #s.render_calls)
    assert.equals(0, #s.clear_calls)
    assert.equals(0, #s.provider.calls.detect_pr)
  end)

  it("does nothing when no provider matches the vcs_info", function()
    local s = setup({
      no_provider = true,
      pr = SAMPLE_PR,
    })

    read_service.refresh_async(1)
    vim.wait(50, function()
      return false
    end)

    assert.equals(0, #s.render_calls)
    assert.equals(0, #s.clear_calls)
    assert.is_nil(s.provider)
  end)

  it("does nothing when the buffer path is outside the repo root", function()
    local s = setup({
      path = "/some/other/place/file.lua",
      pr = SAMPLE_PR,
    })

    read_service.refresh_async(1)
    vim.wait(50, function()
      return false
    end)

    assert.equals(0, #s.render_calls)
    assert.equals(0, #s.provider.calls.detect_pr)
  end)

  it("does nothing when the branch is nil (detached HEAD)", function()
    local s = setup({
      vcs_info = {
        vcs = "git",
        root = "/repo",
        branch = nil,
        remote_url = "git@github.com:owner/repo.git",
      },
      pr = SAMPLE_PR,
    })

    read_service.refresh_async(1)
    vim.wait(50, function()
      return false
    end)

    assert.equals(0, #s.provider.calls.detect_pr)
  end)
end)

-- ---------------------------------------------------------------------------
-- refresh_async — async coroutine integration
-- ---------------------------------------------------------------------------

describe("parley.services.read refresh_async", function()
  before_each(function()
    save_seams()
    progress_ui_state.clear()
  end)

  after_each(function()
    vim.wait(20, function()
      return false
    end)
    restore_seams()
    registry.reset()
    progress_ui_state.clear()
  end)

  it("invokes refresh inside an async coroutine", function()
    local s = setup({ pr = SAMPLE_PR, discussions = {} })

    read_service.refresh_async(1)
    -- async.run schedules; let plenary's scheduler drain.
    -- A tiny vim.wait suffices because all our seams are synchronous.
    assert.is_true(vim.wait(200, function()
      return #s.provider.calls.detect_pr > 0
    end))

    assert.equals(1, #s.provider.calls.detect_pr)
  end)
end)

-- ---------------------------------------------------------------------------
-- Two buffers, two repos, two providers
-- ---------------------------------------------------------------------------
--
-- Verifies the per-buffer / per-(provider,owner,repo,branch) isolation
-- property: when two buffers belong to different repos served by different
-- providers, their context, provider snapshot, review_key, signs, and view
-- state must not collide.

describe("parley.services.read multi-repo", function()
  before_each(function()
    save_seams()
    progress_ui_state.clear()
  end)

  after_each(function()
    vim.wait(20, function()
      return false
    end)
    restore_seams()
    registry.reset()
    progress_ui_state.clear()
  end)

  --- Two-repo setup. Each bufnr maps to its own path/vcs_info/provider.
  ---
  --- @param o {
  ---   buf_a: integer, path_a: string,
  ---   buf_b: integer, path_b: string,
  ---   pr_a: parley.PR, discussions_a: parley.Discussion[],
  ---   pr_b: parley.PR, discussions_b: parley.Discussion[],
  --- }
  local function setup_two_repos(o)
    local vcs_a = {
      vcs = "git",
      root = "/repo-a",
      branch = "feature-a",
      remote_url = "git@host-a.example.com:owner-a/repo-a.git",
    }
    local vcs_b = {
      vcs = "git",
      root = "/repo-b",
      branch = "feature-b",
      remote_url = "git@host-b.example.com:owner-b/repo-b.git",
    }

    buffer_context._get_buf_props = function(bufnr)
      if bufnr == o.buf_a then
        return { filetype = "", name = o.path_a, buftype = "" }
      elseif bufnr == o.buf_b then
        return { filetype = "", name = o.path_b, buftype = "" }
      end
      return { filetype = "", name = "", buftype = "" }
    end
    buffer_context._vcs_detect = function(path)
      if path == o.path_a then
        return vcs_a
      elseif path == o.path_b then
        return vcs_b
      end
      return nil
    end

    anchor._runner = function(_cmd, _cwd)
      return { code = 0, stdout = "", stderr = "" }
    end

    local render_calls = {}
    signs.render = function(bufnr, discussions, mappings, opts)
      table.insert(render_calls, {
        bufnr = bufnr,
        discussions = discussions,
        mappings = mappings,
        opts = opts,
      })
    end
    local clear_calls = {}
    signs.clear = function(bufnr)
      table.insert(clear_calls, bufnr)
    end

    local fake_fs = make_fake_fs()
    cache._fs = fake_fs
    cache.setup({ cache_dir = "/cache" })

    read_service._notify = function(_msg, _level) end
    read_service._get_config = function()
      return SAMPLE_CONFIG
    end

    async_operation._defer = function(_cb, _timeout) end
    async_operation._get_config = function()
      return { progress = { success_timeout = 2500, failed_timeout = 2500 } }
    end

    -- Reset all per-test state.
    review_repository._reviews = {}
    review_repository._views = {}
    review_repository._bufnr_key = {}
    review_repository._key_bufnrs = {}
    review_repository._in_flight = {}
    review_repository._pending_force = {}
    review_repository._subscribers = {}
    context_repository._entries = {}
    provider_repository._entries = {}
    read_service._subscriptions = {}

    -- Two providers, two specs. detect() inspects the remote URL.
    local provider_a = mock_provider.new({
      pr = o.pr_a,
      head_sha = "deadbeef",
      write_context = { number = tonumber(o.pr_a.id), head_sha = "deadbeef" },
      discussions = o.discussions_a,
    })
    provider_a._cache_provider = "host-a"

    local provider_b = mock_provider.new({
      pr = o.pr_b,
      head_sha = "deadbeef",
      write_context = { number = tonumber(o.pr_b.id), head_sha = "deadbeef" },
      discussions = o.discussions_b,
    })
    provider_b._cache_provider = "host-b"

    registry.reset()
    registry.register({
      name = "MockHostA",
      detect = function(vcs)
        if vcs.remote_url:find("host-a", 1, true) then
          return { host = "host-a", repository = "owner-a/repo-a" }
        end
        return nil
      end,
      factory = function(_opts)
        return provider_a
      end,
    })
    registry.register({
      name = "MockHostB",
      detect = function(vcs)
        if vcs.remote_url:find("host-b", 1, true) then
          return { host = "host-b", repository = "owner-b/repo-b" }
        end
        return nil
      end,
      factory = function(_opts)
        return provider_b
      end,
    })

    return {
      provider_a = provider_a,
      provider_b = provider_b,
      render_calls = render_calls,
      clear_calls = clear_calls,
    }
  end

  it("isolates state across two buffers in different repos with different providers", function()
    local pr_a = model.new_pr({
      id = "10",
      title = "A",
      state = "open",
      base_branch = "main",
      head_branch = "feature-a",
      author = "alice",
      url = "https://host-a.example.com/owner-a/repo-a/pull/10",
      review_status = "pending",
    })
    local pr_b = model.new_pr({
      id = "20",
      title = "B",
      state = "open",
      base_branch = "main",
      head_branch = "feature-b",
      author = "bob",
      url = "https://host-b.example.com/owner-b/repo-b/pull/20",
      review_status = "pending",
    })

    local s = setup_two_repos({
      buf_a = 101,
      path_a = "/repo-a/src/foo.lua",
      buf_b = 202,
      path_b = "/repo-b/lib/bar.lua",
      pr_a = pr_a,
      discussions_a = {
        make_discussion(1, "src/foo.lua", 10, "from A"),
      },
      pr_b = pr_b,
      discussions_b = {
        make_discussion(2, "lib/bar.lua", 5, "from B"),
      },
    })

    read_service.refresh_async(101)
    read_service.refresh_async(202)

    assert.is_true(vim.wait(500, function()
      return #s.provider_a.calls.detect_pr >= 1 and #s.provider_b.calls.detect_pr >= 1 and #s.render_calls >= 2
    end))

    -- Each provider was hit for its own repo only.
    assert.equals(1, #s.provider_a.calls.detect_pr)
    assert.equals(1, #s.provider_b.calls.detect_pr)
    assert.equals("/repo-a", s.provider_a.calls.detect_pr[1].repo_root)
    assert.equals("feature-a", s.provider_a.calls.detect_pr[1].branch)
    assert.equals("/repo-b", s.provider_b.calls.detect_pr[1].repo_root)
    assert.equals("feature-b", s.provider_b.calls.detect_pr[1].branch)

    -- Two render calls, one per buffer, each with its own discussions.
    local rc_a, rc_b
    for _, rc in ipairs(s.render_calls) do
      if rc.bufnr == 101 then
        rc_a = rc
      elseif rc.bufnr == 202 then
        rc_b = rc
      end
    end
    assert.is_not_nil(rc_a, "expected a render for bufnr 101")
    assert.is_not_nil(rc_b, "expected a render for bufnr 202")
    assert.equals(1, #rc_a.discussions)
    assert.equals("1", rc_a.discussions[1].id)
    assert.equals(1, #rc_b.discussions)
    assert.equals("2", rc_b.discussions[1].id)

    -- Per-buffer provider snapshots.
    local snap_a = provider_repository.get(101)
    local snap_b = provider_repository.get(202)
    assert.is_not_nil(snap_a)
    assert.is_not_nil(snap_b)
    assert.equals("host-a", snap_a.provider._cache_provider)
    assert.equals("host-b", snap_b.provider._cache_provider)
    assert.are_not.equal(snap_a.provider, snap_b.provider)
    assert.equals("owner-a/repo-a", snap_a.opts.repository)
    assert.equals("owner-b/repo-b", snap_b.opts.repository)

    -- Composite review keys are distinct and both present.
    local key_a = "host-a/owner-a/repo-a/feature-a"
    local key_b = "host-b/owner-b/repo-b/feature-b"
    assert.is_not_nil(review_repository._reviews[key_a])
    assert.is_not_nil(review_repository._reviews[key_b])
    assert.equals(key_a, review_repository._bufnr_key[101])
    assert.equals(key_b, review_repository._bufnr_key[202])

    -- Reverse index: each key holds exactly its own bufnr.
    assert.is_true(review_repository._key_bufnrs[key_a][101])
    assert.is_nil(review_repository._key_bufnrs[key_a][202])
    assert.is_true(review_repository._key_bufnrs[key_b][202])
    assert.is_nil(review_repository._key_bufnrs[key_b][101])

    -- Per-buffer state surfaces the right PR.
    local state_a = read_service.get_buffer_state(101)
    local state_b = read_service.get_buffer_state(202)
    assert.equals("10", state_a.pr.id)
    assert.equals("20", state_b.pr.id)
  end)

  it("a refresh on one repo does not republish into the other repo's buffers", function()
    local pr_a = model.new_pr({
      id = "10",
      title = "A",
      state = "open",
      base_branch = "main",
      head_branch = "feature-a",
      author = "alice",
      url = "https://host-a.example.com/owner-a/repo-a/pull/10",
      review_status = "pending",
    })
    local pr_b = model.new_pr({
      id = "20",
      title = "B",
      state = "open",
      base_branch = "main",
      head_branch = "feature-b",
      author = "bob",
      url = "https://host-b.example.com/owner-b/repo-b/pull/20",
      review_status = "pending",
    })

    local s = setup_two_repos({
      buf_a = 101,
      path_a = "/repo-a/src/foo.lua",
      buf_b = 202,
      path_b = "/repo-b/lib/bar.lua",
      pr_a = pr_a,
      discussions_a = { make_discussion(1, "src/foo.lua", 10, "from A") },
      pr_b = pr_b,
      discussions_b = { make_discussion(2, "lib/bar.lua", 5, "from B") },
    })

    read_service.refresh_async(101)
    read_service.refresh_async(202)
    assert.is_true(vim.wait(500, function()
      return #s.render_calls >= 2
    end))

    -- Drop renders observed during the initial fetch, then force a refresh
    -- on repo A only and verify no extra render lands on bufnr 202.
    local renders_before = #s.render_calls
    read_service.refresh_async(101, { force = true })
    assert.is_true(vim.wait(500, function()
      return #s.provider_a.calls.detect_pr >= 2
    end))

    assert.equals(2, #s.provider_a.calls.detect_pr, "repo A re-fetched")
    assert.equals(1, #s.provider_b.calls.detect_pr, "repo B should NOT re-fetch")

    for i = renders_before + 1, #s.render_calls do
      assert.equals(101, s.render_calls[i].bufnr, "only bufnr 101 should re-render")
    end
  end)
end)
