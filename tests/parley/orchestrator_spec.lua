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
---
--- No real filesystem, network, or git invocations.

local async_tests = require("plenary.async.tests")

local anchor = require("parley.anchor")
local buffer_context = require("parley.buffer_context")
local cache = require("parley.cache")
local mock_provider = require("parley.mock_provider")
local model = require("parley.model")
local read_service = require("parley.services.read")
local registry = require("parley.registry")
local signs = require("parley.signs")

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

  -- Reentrancy guard: clear any state from previous tests.
  for k in pairs(read_service._in_flight) do
    read_service._in_flight[k] = nil
  end
  for k in pairs(read_service._pending_force) do
    read_service._pending_force[k] = nil
  end

  -- Provider via the registry.
  registry.reset()
  local provider = nil
  if not o.no_provider then
    provider = mock_provider.new({
      pr = o.pr,
      discussions = o.discussions or {},
    })
    if o.provider_error then
      provider:set_error(o.provider_error.method, o.provider_error.msg)
    end
    -- Add a head_sha accessor that the orchestrator uses.
    provider.head_sha = function(_self, _pr)
      return "deadbeef"
    end
    registry.register({
      name = "MockGitHub",
      detect = function(_vcs)
        return { host = "github.com", owner = "owner", repo = "repo" }
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

async_tests.describe("parley.services.read refresh", function()
  async_tests.before_each(function()
    save_seams()
  end)

  async_tests.after_each(function()
    restore_seams()
    registry.reset()
  end)

  -- -------------------------------------------------------------------------
  -- 1. Happy path
  -- -------------------------------------------------------------------------

  async_tests.it("renders signs for the current file's discussions only", function()
    local s = setup({
      path = "/repo/src/foo.lua",
      pr = SAMPLE_PR,
      discussions = {
        make_discussion(1, "src/foo.lua", 10, "for foo"),
        make_discussion(2, "src/foo.lua", 20, "also foo"),
        make_discussion(3, "src/bar.lua", 5, "for bar"),
      },
    })

    read_service.refresh(1)

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

  async_tests.it("calls detect_pr and fetch_discussions on the provider", function()
    local s = setup({ pr = SAMPLE_PR, discussions = {} })

    read_service.refresh(1)

    assert.equals(1, #s.provider.calls.detect_pr)
    assert.equals(1, #s.provider.calls.fetch_discussions)
    assert.equals("feature", s.provider.calls.detect_pr[1].branch)
    assert.equals("/repo", s.provider.calls.detect_pr[1].repo_root)
  end)

  -- -------------------------------------------------------------------------
  -- 2. No PR detected
  -- -------------------------------------------------------------------------

  async_tests.it("clears signs when detect_pr returns nil (no PR for branch)", function()
    local s = setup({ pr = nil })

    read_service._buffer_state[1] = {
      discussions = { make_discussion(99, "src/foo.lua", 5, "stale") },
      mappings = { ["99"] = { local_line = 5, stale = false, confidence = 1.0 } },
    }

    read_service.refresh(1)

    assert.equals(0, #s.render_calls)
    assert.is_true(#s.clear_calls >= 1)
    assert.equals(1, s.clear_calls[#s.clear_calls])
    assert.is_nil(read_service.get_buffer_state(1))
  end)

  async_tests.it("removes the cached PR record when detect_pr returns nil", function()
    local s = setup({ pr = nil })

    -- Pre-seed the cache with a stale PR record so we can verify it goes away.
    cache.set(
      { provider = "github", repository = "owner/repo", subkey = "pr_branch_feature" },
      { id = "old", head_sha = "deadbeef" }
    )
    assert.is_not_nil(
      cache.get({ provider = "github", repository = "owner/repo", subkey = "pr_branch_feature" }),
      "precondition: cache should hold the seeded entry"
    )

    read_service.refresh(1)

    local entry = cache.get({ provider = "github", repository = "owner/repo", subkey = "pr_branch_feature" })
    assert.is_nil(entry)
    -- Suppress unused warning.
    assert.is_table(s.fs._files)
  end)

  -- -------------------------------------------------------------------------
  -- 3 & 4. Stale-while-revalidate behaviour
  -- -------------------------------------------------------------------------

  async_tests.it("renders cached data first, then fresh data, when force=false", function()
    local s = setup({
      pr = SAMPLE_PR,
      discussions = { make_discussion(1, "src/foo.lua", 10, "fresh") },
    })

    -- Pre-seed cache (after setup so the in-memory fs is in place).
    cache.set(
      { provider = "github", repository = "owner/repo", subkey = "pr_branch_feature" },
      { id = "42", head_sha = "deadbeef" }
    )
    cache.set(
      { provider = "github", repository = "owner/repo", subkey = "discussions_42" },
      { make_discussion(99, "src/foo.lua", 5, "stale") }
    )

    read_service.refresh(1)

    -- Expect 2 renders: stale (id 99) then fresh (id 1).
    assert.equals(2, #s.render_calls)
    assert.equals("99", s.render_calls[1].discussions[1].id)
    assert.equals("1", s.render_calls[2].discussions[1].id)
  end)

  async_tests.it("skips the stale render when force=true", function()
    local s = setup({
      pr = SAMPLE_PR,
      discussions = { make_discussion(1, "src/foo.lua", 10, "fresh") },
    })

    cache.set(
      { provider = "github", repository = "owner/repo", subkey = "pr_branch_feature" },
      { id = "42", head_sha = "deadbeef" }
    )
    cache.set(
      { provider = "github", repository = "owner/repo", subkey = "discussions_42" },
      { make_discussion(99, "src/foo.lua", 5, "stale") }
    )

    read_service.refresh(1, { force = true })

    assert.equals(1, #s.render_calls)
    assert.equals("1", s.render_calls[1].discussions[1].id)
  end)

  -- -------------------------------------------------------------------------
  -- 5. Error path
  -- -------------------------------------------------------------------------

  async_tests.it("notifies and leaves stale render in place when fetch raises", function()
    local s = setup({
      pr = SAMPLE_PR,
      discussions = {},
      provider_error = { method = "fetch_discussions", msg = "network down" },
    })

    -- Pre-seed cache so the stale render runs first (after setup so fake fs is in place).
    cache.set(
      { provider = "github", repository = "owner/repo", subkey = "pr_branch_feature" },
      { id = "42", head_sha = "deadbeef" }
    )
    cache.set(
      { provider = "github", repository = "owner/repo", subkey = "discussions_42" },
      { make_discussion(99, "src/foo.lua", 5, "stale") }
    )

    read_service.refresh(1)

    -- Stale render happened.
    assert.equals(1, #s.render_calls)
    assert.equals("99", s.render_calls[1].discussions[1].id)
    -- And we got a warn-level notify.
    assert.equals(1, #s.notify_calls)
    assert.equals(vim.log.levels.WARN, s.notify_calls[1].level)
    assert.is_not_nil(s.notify_calls[1].msg:find("parley"))
    assert.equals("99", read_service.get_buffer_state(1).discussions[1].id)
  end)

  async_tests.it("stays silent for background refresh failures when notify_errors=false", function()
    local s = setup({
      pr = SAMPLE_PR,
      discussions = {},
      provider_error = { method = "fetch_discussions", msg = "network down" },
    })

    cache.set(
      { provider = "github", repository = "owner/repo", subkey = "pr_branch_feature" },
      { id = "42", head_sha = "deadbeef" }
    )
    cache.set(
      { provider = "github", repository = "owner/repo", subkey = "discussions_42" },
      { make_discussion(99, "src/foo.lua", 5, "stale") }
    )

    read_service.refresh(1, { notify_errors = false })

    assert.equals(1, #s.render_calls)
    assert.equals(0, #s.notify_calls)
    assert.equals("99", read_service.get_buffer_state(1).discussions[1].id)
  end)

  async_tests.it("clears buffer state when the current file has no discussions", function()
    local s = setup({
      path = "/repo/src/foo.lua",
      pr = SAMPLE_PR,
      discussions = { make_discussion(1, "src/bar.lua", 10, "for bar") },
    })

    read_service._buffer_state[1] = {
      discussions = { make_discussion(99, "src/foo.lua", 5, "stale") },
      mappings = { ["99"] = { local_line = 5, stale = false, confidence = 1.0 } },
    }

    read_service.refresh(1)

    assert.equals(1, #s.clear_calls)
    assert.is_nil(read_service.get_buffer_state(1))
  end)

  -- -------------------------------------------------------------------------
  -- 6. Reentrancy
  -- -------------------------------------------------------------------------

  async_tests.it("returns immediately when a refresh is already in flight for this bufnr", function()
    local s = setup({ pr = SAMPLE_PR, discussions = {} })

    -- Simulate an in-flight call.
    read_service._in_flight[1] = true

    read_service.refresh(1)

    assert.equals(0, #s.provider.calls.detect_pr)
    assert.equals(0, #s.render_calls)

    read_service._in_flight[1] = nil
  end)

  async_tests.it("queues a forced rerun when force=true arrives during an in-flight refresh", function()
    local s = setup({ pr = SAMPLE_PR, discussions = {} })

    read_service._in_flight[1] = true

    read_service.refresh(1, { force = true })

    assert.is_true(read_service._pending_force[1])
    assert.equals(0, #s.provider.calls.detect_pr)

    read_service._in_flight[1] = nil
    read_service._pending_force[1] = nil
  end)

  -- -------------------------------------------------------------------------
  -- 7. Non-regular buffers are silently skipped
  -- -------------------------------------------------------------------------

  async_tests.it("does nothing for a diffview buffer", function()
    local s = setup({
      filetype = "DiffviewFiles",
      pr = SAMPLE_PR,
    })

    read_service.refresh(1)

    assert.equals(0, #s.render_calls)
    assert.equals(0, #s.clear_calls)
    assert.equals(0, #s.provider.calls.detect_pr)
  end)

  async_tests.it("does nothing for a non-VCS buffer", function()
    local s = setup({
      vcs_info = false,
      pr = SAMPLE_PR,
    })

    read_service.refresh(1)

    assert.equals(0, #s.render_calls)
    assert.equals(0, #s.clear_calls)
    assert.equals(0, #s.provider.calls.detect_pr)
  end)

  async_tests.it("does nothing when no provider matches the vcs_info", function()
    local s = setup({
      no_provider = true,
      pr = SAMPLE_PR,
    })

    read_service.refresh(1)

    assert.equals(0, #s.render_calls)
    assert.equals(0, #s.clear_calls)
    assert.is_nil(s.provider)
  end)

  async_tests.it("does nothing when the buffer path is outside the repo root", function()
    local s = setup({
      path = "/some/other/place/file.lua",
      pr = SAMPLE_PR,
    })

    read_service.refresh(1)

    assert.equals(0, #s.render_calls)
    assert.equals(0, #s.provider.calls.detect_pr)
  end)

  async_tests.it("does nothing when the branch is nil (detached HEAD)", function()
    local s = setup({
      vcs_info = {
        vcs = "git",
        root = "/repo",
        branch = nil,
        remote_url = "git@github.com:owner/repo.git",
      },
      pr = SAMPLE_PR,
    })

    read_service.refresh(1)

    assert.equals(0, #s.provider.calls.detect_pr)
  end)
end)

-- ---------------------------------------------------------------------------
-- refresh_async — sync wrapper
-- ---------------------------------------------------------------------------

describe("parley.services.read refresh_async", function()
  before_each(function()
    save_seams()
  end)

  after_each(function()
    restore_seams()
    registry.reset()
  end)

  it("invokes refresh inside an async coroutine", function()
    local s = setup({ pr = SAMPLE_PR, discussions = {} })

    read_service.refresh_async(1)
    -- async.run schedules; let plenary's scheduler drain.
    -- A tiny vim.wait suffices because all our seams are synchronous.
    vim.wait(50, function()
      return #s.provider.calls.detect_pr > 0
    end)

    assert.equals(1, #s.provider.calls.detect_pr)
  end)
end)
