--- tests/parley/services/read_spec.lua — read service refresh_async.

local async_operation = require("parley.async_operation")
local context_repository = require("parley.repositories.context")
local provider_repository = require("parley.repositories.provider")
local review_repository = require("parley.repositories.review")
local progress_ui_state = require("parley.ui_states.progress")
local read_service = require("parley.services.read")

local saved = {}

local function save_seams()
  saved.async_run = async_operation._async_run
  saved.defer = async_operation._defer
  saved.get_config = async_operation._get_config
  saved.notify = read_service._notify
  saved.ctx_refresh = context_repository.refresh
  saved.prov_refresh = provider_repository.refresh
  saved.prov_get = provider_repository.get
  saved.review_refresh = review_repository.refresh
  saved.review_has = review_repository.has_review
  saved.review_make_key = review_repository.make_key
end

local function restore_seams()
  async_operation._async_run = saved.async_run
  async_operation._defer = saved.defer
  async_operation._get_config = saved.get_config
  read_service._notify = saved.notify
  context_repository.refresh = saved.ctx_refresh
  provider_repository.refresh = saved.prov_refresh
  provider_repository.get = saved.prov_get
  review_repository.refresh = saved.review_refresh
  review_repository.has_review = saved.review_has
  review_repository.make_key = saved.review_make_key
end

--- Make async_operation run synchronously for deterministic tests.
--- Returns accumulated deferred callbacks.
local function use_sync_async()
  local ctx = { deferred = {} }
  async_operation._async_run = function(fn)
    fn()
  end
  async_operation._now = function()
    return 1000
  end
  async_operation._defer = function(cb, timeout)
    ctx.deferred[#ctx.deferred + 1] = { cb = cb, timeout = timeout }
  end
  async_operation._get_config = function()
    return { progress = { success_timeout = 2500, failed_timeout = 2500 } }
  end
  return ctx
end

local PROVIDER_SNAPSHOT = {
  status = "ready",
  provider = {},
  opts = { owner = "owner", repo = "repo", host = "github.com" },
}

--- Seed standard VCS context for bufnr 1.
local function seed_vcs_context()
  context_repository.refresh = function(_bufnr)
    return {
      kind = "regular",
      bufnr = 1,
      path = "/repo/src/foo.lua",
      vcs_info = {
        vcs = "git",
        root = "/repo",
        branch = "feature",
        remote_url = "git@github.com:owner/repo.git",
      },
      rel_path = "src/foo.lua",
      status = "ready",
    }
  end
  provider_repository.refresh = function(_bufnr)
    return PROVIDER_SNAPSHOT
  end
  provider_repository.get = function(_bufnr)
    return PROVIDER_SNAPSHOT
  end
  review_repository.make_key = function(_ps, _ctx)
    return "test/owner/repo/feature"
  end
end

--- Seed a successful review snapshot for bufnr 1 in the review repository.
local function seed_snapshot()
  review_repository._seed(1, {
    status = "ready",
    stale = false,
    review = { pr = { id = "42" }, head_sha = "abc" },
    discussions = {},
    all_discussions = {},
    mappings = {},
    summary = { unresolved_count = 0 },
    error = nil,
    head_sha = "abc",
  })
  review_repository.has_review = function(_key)
    return true
  end
end

describe("parley.services.read", function()
  local notify_calls

  before_each(function()
    save_seams()
    progress_ui_state.clear()
    review_repository._reviews = {}
    review_repository._views = {}
    review_repository._bufnr_key = {}
    review_repository._key_bufnrs = {}
    read_service._subscriptions = {}
    notify_calls = {}
    read_service._notify = function(msg, level)
      notify_calls[#notify_calls + 1] = { msg = msg, level = level }
    end
  end)

  after_each(function()
    vim.wait(20, function()
      return false
    end)
    restore_seams()
    progress_ui_state.clear()
    review_repository._reviews = {}
    review_repository._views = {}
    review_repository._bufnr_key = {}
    review_repository._key_bufnrs = {}
    read_service._subscriptions = {}
  end)

  -- -------------------------------------------------------------------------
  -- Early-exit guards
  -- -------------------------------------------------------------------------

  describe("early-exit guards", function()
    it("does nothing for a non-VCS buffer (kind ~= regular)", function()
      use_sync_async()
      context_repository.refresh = function(_bufnr)
        return { kind = "non_vcs", bufnr = 1, path = "/tmp/foo.txt" }
      end

      local op_created = false
      local orig_new = async_operation.new
      async_operation.new = function(opts)
        op_created = true
        return orig_new(opts)
      end

      read_service.refresh_async(1)
      assert.is_false(op_created)
      assert.same({}, progress_ui_state.list())

      async_operation.new = orig_new
    end)

    it("does nothing when rel_path is absent", function()
      use_sync_async()
      context_repository.refresh = function(_bufnr)
        return {
          kind = "regular",
          bufnr = 1,
          path = "/repo/foo.lua",
          vcs_info = { vcs = "git", root = "/repo", branch = "feature" },
          rel_path = nil, -- missing
        }
      end

      local op_created = false
      local orig_new = async_operation.new
      async_operation.new = function(opts)
        op_created = true
        return orig_new(opts)
      end

      read_service.refresh_async(1)
      assert.is_false(op_created)

      async_operation.new = orig_new
    end)

    it("does nothing when branch is empty", function()
      use_sync_async()
      context_repository.refresh = function(_bufnr)
        return {
          kind = "regular",
          bufnr = 1,
          path = "/repo/foo.lua",
          vcs_info = { vcs = "git", root = "/repo", branch = "" },
          rel_path = "foo.lua",
        }
      end

      local op_created = false
      local orig_new = async_operation.new
      async_operation.new = function(opts)
        op_created = true
        return orig_new(opts)
      end

      read_service.refresh_async(1)
      assert.is_false(op_created)

      async_operation.new = orig_new
    end)

    it("does nothing when provider detection fails", function()
      use_sync_async()
      context_repository.refresh = function(_bufnr)
        return {
          kind = "regular",
          bufnr = 1,
          path = "/repo/foo.lua",
          vcs_info = { vcs = "git", root = "/repo", branch = "main" },
          rel_path = "foo.lua",
        }
      end
      provider_repository.refresh = function(_bufnr)
        return nil -- no provider detected
      end

      local op_created = false
      local orig_new = async_operation.new
      async_operation.new = function(opts)
        op_created = true
        return orig_new(opts)
      end

      read_service.refresh_async(1)
      assert.is_false(op_created)

      async_operation.new = orig_new
    end)
  end)

  -- -------------------------------------------------------------------------
  -- silent flag
  -- -------------------------------------------------------------------------

  describe("silent determination", function()
    it("silent = false when no existing review data (cold cache / first-time fetch)", function()
      use_sync_async()
      seed_vcs_context()
      -- No shared review data → has_review returns false
      review_repository.has_review = function(_key)
        return false
      end
      review_repository.refresh = function(_bufnr, _opts)
        return nil
      end

      local captured_silent = nil
      local orig_new = async_operation.new
      async_operation.new = function(opts)
        captured_silent = opts.silent
        return orig_new(opts)
      end

      read_service.refresh_async(1)
      assert.is_false(captured_silent)

      async_operation.new = orig_new
    end)

    it("silent = true when review data already exists (warm cache)", function()
      use_sync_async()
      seed_vcs_context()
      seed_snapshot()
      review_repository.refresh = function(_bufnr, _opts)
        return review_repository.get(1)
      end

      local captured_silent = nil
      local orig_new = async_operation.new
      async_operation.new = function(opts)
        captured_silent = opts.silent
        return orig_new(opts)
      end

      read_service.refresh_async(1)
      assert.is_true(captured_silent)

      async_operation.new = orig_new
    end)

    it("silent = false when opts.progress = true even with existing data", function()
      use_sync_async()
      seed_vcs_context()
      seed_snapshot()
      review_repository.refresh = function(_bufnr, _opts)
        return review_repository.get(1)
      end

      local captured_silent = nil
      local orig_new = async_operation.new
      async_operation.new = function(opts)
        captured_silent = opts.silent
        return orig_new(opts)
      end

      read_service.refresh_async(1, { progress = true })
      assert.is_false(captured_silent)

      async_operation.new = orig_new
    end)
  end)

  -- -------------------------------------------------------------------------
  -- Progress popup shown on cold cache
  -- -------------------------------------------------------------------------

  describe("progress popup on cold cache", function()
    it("shows a running popup when no review data exists", function()
      use_sync_async()
      seed_vcs_context()
      review_repository.has_review = function(_key)
        return false
      end
      review_repository.refresh = function(_bufnr, _opts)
        return nil
      end

      read_service.refresh_async(1)

      assert.is_true(vim.wait(200, function()
        return #progress_ui_state.list() >= 1
      end))

      local entries = progress_ui_state.list()
      assert.equals(1, #entries)
    end)

    it("does not show a popup when review data exists", function()
      use_sync_async()
      seed_vcs_context()
      seed_snapshot()
      review_repository.refresh = function(_bufnr, _opts)
        return review_repository.get(1)
      end

      read_service.refresh_async(1)

      -- Allow any vim.schedule flush
      vim.wait(100, function()
        return false
      end)

      assert.same({}, progress_ui_state.list())
    end)
  end)

  -- -------------------------------------------------------------------------
  -- callback
  -- -------------------------------------------------------------------------

  describe("callback", function()
    it("is called with snapshot on success", function()
      use_sync_async()
      seed_vcs_context()
      seed_snapshot()
      review_repository.refresh = function(_bufnr, _opts)
        return review_repository.get(1)
      end

      local received = nil
      local done = false
      read_service.refresh_async(1, {}, function(snapshot)
        received = snapshot
        done = true
      end)

      assert.is_true(vim.wait(200, function()
        return done
      end))
      assert.is_not_nil(received)
      assert.equals("ready", received.status)
    end)

    it("is called with error snapshot when refresh returns status=error", function()
      use_sync_async()
      seed_vcs_context()
      review_repository.has_review = function(_key)
        return false
      end
      review_repository.refresh = function(_bufnr, _opts)
        return {
          status = "error",
          error = "API failure",
          discussions = {},
          all_discussions = {},
          mappings = {},
          summary = { unresolved_count = 0 },
        }
      end

      local received = nil
      local done = false
      read_service.refresh_async(1, { notify_errors = false }, function(snapshot)
        received = snapshot
        done = true
      end)

      assert.is_true(vim.wait(200, function()
        return done
      end))
      -- Callback always receives the snapshot, even on error
      assert.is_not_nil(received)
      assert.equals("error", received.status)
    end)

    it("popup transitions to failed state when refresh returns error snapshot", function()
      use_sync_async()
      seed_vcs_context()
      review_repository.has_review = function(_key)
        return false -- cold cache → silent=false → popup shown
      end
      review_repository.refresh = function(_bufnr, _opts)
        return {
          status = "error",
          error = "network timeout",
          discussions = {},
          all_discussions = {},
          mappings = {},
          summary = { unresolved_count = 0 },
        }
      end

      read_service.refresh_async(1, { notify_errors = false })

      assert.is_true(vim.wait(200, function()
        local entries = progress_ui_state.list()
        return #entries == 1 and entries[1].state == "failed"
      end))

      local entries = progress_ui_state.list()
      assert.equals("failed", entries[1].state)
      assert.equals("Refresh failed", entries[1].message)
    end)

    it("is not required (nil callback is accepted)", function()
      use_sync_async()
      seed_vcs_context()
      review_repository.has_review = function(_key)
        return false
      end
      review_repository.refresh = function(_bufnr, _opts)
        return nil
      end

      assert.has_no.errors(function()
        read_service.refresh_async(1)
        vim.wait(100, function()
          return false
        end)
      end)
    end)
  end)

  -- -------------------------------------------------------------------------
  -- notify_errors
  -- -------------------------------------------------------------------------

  describe("notify_errors", function()
    it("notifies on error snapshot by default", function()
      use_sync_async()
      seed_vcs_context()
      review_repository.has_review = function(_key)
        return false
      end
      review_repository.refresh = function(_bufnr, _opts)
        return {
          status = "error",
          error = "rate limit",
          discussions = {},
          all_discussions = {},
          mappings = {},
          summary = { unresolved_count = 0 },
        }
      end

      read_service.refresh_async(1)

      assert.is_true(vim.wait(200, function()
        return #notify_calls == 1
      end))
      assert.is_not_nil(notify_calls[1].msg:find("rate limit"))
    end)

    it("suppresses notification when notify_errors = false", function()
      use_sync_async()
      seed_vcs_context()
      review_repository.has_review = function(_key)
        return false
      end
      review_repository.refresh = function(_bufnr, _opts)
        return {
          status = "error",
          error = "rate limit",
          discussions = {},
          all_discussions = {},
          mappings = {},
          summary = { unresolved_count = 0 },
        }
      end

      read_service.refresh_async(1, { notify_errors = false })

      vim.wait(100, function()
        return false
      end)
      assert.same({}, notify_calls)
    end)
  end)
end)
