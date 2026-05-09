--- tests/parley/async_operation_spec.lua — AsyncOperation wrapper.

local async_operation = require("parley.async_operation")
local progress_ui_state = require("parley.ui_states.progress")

local saved = {}

local function save_seams()
  saved.async_run = async_operation._async_run
  saved.now = async_operation._now
  saved.defer = async_operation._defer
  saved.get_config = async_operation._get_config
end

local function restore_seams()
  async_operation._async_run = saved.async_run
  async_operation._now = saved.now
  async_operation._defer = saved.defer
  async_operation._get_config = saved.get_config
end

--- Replace async_run with a synchronous version.
--- Returns a table that accumulates deferred callbacks without firing them,
--- so tests can assert on progress state before entries are removed.
--- @return { deferred: { cb: fun(), timeout: integer }[] }
local function use_sync_seams()
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

local function make_popup()
  return { progress = "Working...", success = "Done", error = "Failed" }
end

describe("parley.async_operation", function()
  before_each(function()
    save_seams()
    progress_ui_state.clear()
    async_operation._next_id = 0
  end)

  after_each(function()
    -- Drain any pending vim.schedule callbacks before restoring seams.
    -- Without this, a callback queued by the sync _async_run seam fires during
    -- the next test's vim.wait, hitting that test's _defer instead of ours.
    vim.wait(20, function()
      return false
    end)
    restore_seams()
    progress_ui_state.clear()
  end)

  -- -------------------------------------------------------------------------
  -- M.new — validation
  -- -------------------------------------------------------------------------

  describe("M.new", function()
    it("accepts a valid silent operation without popup", function()
      assert.has_no.errors(function()
        async_operation.new({
          bufnr = 1,
          silent = true,
          fn = function() end,
        })
      end)
    end)

    it("accepts a valid non-silent operation with popup", function()
      assert.has_no.errors(function()
        async_operation.new({
          bufnr = 1,
          silent = false,
          fn = function() end,
          popup = make_popup(),
        })
      end)
    end)

    it("rejects missing bufnr", function()
      assert.has.errors(function()
        async_operation.new({ fn = function() end, silent = true })
      end)
    end)

    it("rejects missing fn", function()
      assert.has.errors(function()
        async_operation.new({ bufnr = 1, silent = true })
      end)
    end)

    it("rejects missing silent", function()
      assert.has.errors(function()
        async_operation.new({ bufnr = 1, fn = function() end })
      end)
    end)

    it("rejects missing popup when silent = false", function()
      assert.has.errors(function()
        async_operation.new({ bufnr = 1, silent = false, fn = function() end })
      end)
    end)

    it("rejects incomplete popup", function()
      assert.has.errors(function()
        async_operation.new({
          bufnr = 1,
          silent = false,
          fn = function() end,
          popup = { progress = "p", success = "s" }, -- missing error
        })
      end)
    end)
  end)

  -- -------------------------------------------------------------------------
  -- silent = true
  -- -------------------------------------------------------------------------

  describe("silent = true", function()
    it("runs fn without touching progress_ui_state", function()
      use_sync_seams()
      local called = false
      async_operation
        .new({
          bufnr = 1,
          silent = true,
          fn = function()
            called = true
          end,
        })
        :start()
      assert.is_true(called)
      assert.same({}, progress_ui_state.list())
    end)

    it("calls finally_scheduled_fn via vim.schedule after fn", function()
      use_sync_seams()
      local order = {}
      local done = false

      async_operation
        .new({
          bufnr = 1,
          silent = true,
          fn = function()
            order[#order + 1] = "fn"
            return "value"
          end,
          finally_scheduled_fn = function(ok, result)
            order[#order + 1] = "finally"
            assert.is_true(ok)
            assert.equals("value", result)
            done = true
          end,
        })
        :start()

      order[#order + 1] = "after_start"

      -- finally_scheduled_fn goes through vim.schedule so it has not fired yet
      assert.same({ "fn", "after_start" }, order)

      assert.is_true(vim.wait(200, function()
        return done
      end))
      assert.same({ "fn", "after_start", "finally" }, order)
    end)

    it("passes error value to finally_scheduled_fn when fn throws", function()
      use_sync_seams()
      local received = {}

      async_operation
        .new({
          bufnr = 1,
          silent = true,
          fn = function()
            error("boom")
          end,
          finally_scheduled_fn = function(ok, result)
            received.ok = ok
            received.result = result
          end,
        })
        :start()

      assert.is_true(vim.wait(200, function()
        return received.ok ~= nil
      end))
      assert.is_false(received.ok)
      assert.is_not_nil(received.result) -- error message string
    end)

    it("does not call finally_scheduled_fn when nil", function()
      use_sync_seams()
      -- Should not error if finally_scheduled_fn is absent
      assert.has_no.errors(function()
        async_operation
          .new({
            bufnr = 1,
            silent = true,
            fn = function() end,
          })
          :start()
      end)
    end)
  end)

  -- -------------------------------------------------------------------------
  -- silent = false — progress lifecycle
  -- -------------------------------------------------------------------------

  describe("silent = false", function()
    it("inserts a running entry synchronously before the coroutine runs", function()
      local fn_saw_entry = nil
      -- Replace _async_run to inspect state at the moment fn runs
      async_operation._async_run = function(fn)
        fn_saw_entry = vim.deepcopy(progress_ui_state.list())
        fn()
      end
      async_operation._now = function()
        return 1000
      end
      async_operation._defer = function() end
      async_operation._get_config = function()
        return { progress = { success_timeout = 2500 } }
      end

      async_operation
        .new({
          bufnr = 1,
          silent = false,
          fn = function() end,
          popup = make_popup(),
        })
        :start()

      -- The running entry must already be present when _async_run is called
      assert.equals(1, #fn_saw_entry)
      assert.equals("running", fn_saw_entry[1].state)
      assert.equals("Working...", fn_saw_entry[1].message)
    end)

    it("transitions to success state after fn returns", function()
      local ctx = use_sync_seams()

      async_operation
        .new({
          bufnr = 1,
          silent = false,
          fn = function()
            return "ok"
          end,
          popup = make_popup(),
        })
        :start()

      assert.is_true(vim.wait(200, function()
        local entries = progress_ui_state.list()
        return #entries == 1 and entries[1].state == "success"
      end))

      local entries = progress_ui_state.list()
      assert.equals("success", entries[1].state)
      assert.equals("Done", entries[1].message)
      assert.equals("Parley", entries[1].title)
      -- defer captured but not yet fired → entry still present
      assert.equals(1, #ctx.deferred)
    end)

    it("transitions to failed state when fn throws", function()
      local ctx = use_sync_seams()

      async_operation
        .new({
          bufnr = 1,
          silent = false,
          fn = function()
            error("something went wrong")
          end,
          popup = make_popup(),
        })
        :start()

      assert.is_true(vim.wait(200, function()
        local entries = progress_ui_state.list()
        return #entries == 1 and entries[1].state == "failed"
      end))

      local entries = progress_ui_state.list()
      assert.equals("failed", entries[1].state)
      assert.equals("Failed", entries[1].message)
      assert.equals(1, #ctx.deferred)
    end)

    it("removes the entry after the deferred timeout fires", function()
      local ctx = use_sync_seams()

      async_operation
        .new({
          bufnr = 1,
          silent = false,
          fn = function() end,
          popup = make_popup(),
        })
        :start()

      assert.is_true(vim.wait(200, function()
        local entries = progress_ui_state.list()
        return #entries == 1 and entries[1].state == "success"
      end))

      -- Manually fire the deferred removal
      assert.equals(1, #ctx.deferred)
      ctx.deferred[1].cb()

      assert.same({}, progress_ui_state.list())
    end)

    it("deferred timeout matches success_timeout from config", function()
      local ctx = use_sync_seams()
      async_operation._get_config = function()
        return { progress = { success_timeout = 999, failed_timeout = 888 } }
      end

      async_operation
        .new({
          bufnr = 1,
          silent = false,
          fn = function() end,
          popup = make_popup(),
        })
        :start()

      assert.is_true(vim.wait(200, function()
        return #ctx.deferred == 1
      end))
      assert.equals(999, ctx.deferred[1].timeout)
    end)

    it("deferred timeout matches failed_timeout from config", function()
      local ctx = use_sync_seams()
      async_operation._get_config = function()
        return { progress = { success_timeout = 999, failed_timeout = 888 } }
      end

      async_operation
        .new({
          bufnr = 1,
          silent = false,
          fn = function()
            error("fail")
          end,
          popup = make_popup(),
        })
        :start()

      assert.is_true(vim.wait(200, function()
        return #ctx.deferred == 1
      end))
      assert.equals(888, ctx.deferred[1].timeout)
    end)

    it("uses custom title when provided", function()
      use_sync_seams()

      async_operation
        .new({
          bufnr = 1,
          silent = false,
          title = "MyTitle",
          fn = function() end,
          popup = make_popup(),
        })
        :start()

      assert.is_true(vim.wait(200, function()
        local entries = progress_ui_state.list()
        return #entries == 1 and entries[1].state == "success"
      end))
      assert.equals("MyTitle", progress_ui_state.list()[1].title)
    end)

    it("defaults title to 'Parley'", function()
      use_sync_seams()

      async_operation
        .new({
          bufnr = 1,
          silent = false,
          fn = function() end,
          popup = make_popup(),
        })
        :start()

      assert.is_true(vim.wait(200, function()
        local entries = progress_ui_state.list()
        return #entries == 1 and entries[1].state == "success"
      end))
      assert.equals("Parley", progress_ui_state.list()[1].title)
    end)
  end)

  -- -------------------------------------------------------------------------
  -- finally_scheduled_fn — ordering and context
  -- -------------------------------------------------------------------------

  describe("finally_scheduled_fn", function()
    it("is called after start() returns, not inline (correct scheduling order)", function()
      use_sync_seams()
      local order = {}
      local done = false

      async_operation
        .new({
          bufnr = 1,
          silent = false,
          fn = function()
            order[#order + 1] = "fn"
            return "snapshot"
          end,
          popup = make_popup(),
          finally_scheduled_fn = function(ok, result)
            order[#order + 1] = "finally"
            assert.is_true(ok)
            assert.equals("snapshot", result)
            done = true
          end,
        })
        :start()

      order[#order + 1] = "after_start"

      -- fn ran synchronously; finally_scheduled_fn is in vim.schedule queue
      assert.same({ "fn", "after_start" }, order)

      assert.is_true(vim.wait(200, function()
        return done
      end))
      assert.same({ "fn", "after_start", "finally" }, order)
    end)

    it("receives the error value when fn throws", function()
      use_sync_seams()
      local received = {}

      async_operation
        .new({
          bufnr = 1,
          silent = false,
          fn = function()
            error("kaboom")
          end,
          popup = make_popup(),
          finally_scheduled_fn = function(ok, result)
            received.ok = ok
            received.result = result
          end,
        })
        :start()

      assert.is_true(vim.wait(200, function()
        return received.ok ~= nil
      end))
      assert.is_false(received.ok)
      assert.is_not_nil(received.result)
    end)

    it("is not called when nil", function()
      use_sync_seams()
      -- Must not error when finally_scheduled_fn is absent
      assert.has_no.errors(function()
        async_operation
          .new({
            bufnr = 1,
            silent = false,
            fn = function() end,
            popup = make_popup(),
          })
          :start()
        vim.wait(100, function()
          return false
        end)
      end)
    end)
  end)

  -- -------------------------------------------------------------------------
  -- notify field
  -- -------------------------------------------------------------------------

  describe("notify", function()
    it("calls vim.notify with success message on success", function()
      use_sync_seams()
      local notified = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level)
        notified[#notified + 1] = { msg = msg, level = level }
      end

      async_operation
        .new({
          bufnr = 1,
          silent = false,
          fn = function() end,
          popup = make_popup(),
          notify = { success = "All done!", error = "Oops" },
        })
        :start()

      assert.is_true(vim.wait(200, function()
        return #notified == 1
      end))
      assert.equals("All done!", notified[1].msg)
      assert.equals(vim.log.levels.INFO, notified[1].level)

      vim.notify = orig_notify
    end)

    it("calls vim.notify with error message on failure", function()
      use_sync_seams()
      local notified = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level)
        notified[#notified + 1] = { msg = msg, level = level }
      end

      async_operation
        .new({
          bufnr = 1,
          silent = false,
          fn = function()
            error("bad")
          end,
          popup = make_popup(),
          notify = { success = "All done!", error = "Oops" },
        })
        :start()

      assert.is_true(vim.wait(200, function()
        return #notified == 1
      end))
      assert.equals("Oops", notified[1].msg)
      assert.equals(vim.log.levels.WARN, notified[1].level)

      vim.notify = orig_notify
    end)

    it("does not notify when notify field is absent", function()
      use_sync_seams()
      local notified = {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level)
        notified[#notified + 1] = { msg = msg, level = level }
      end

      async_operation
        .new({
          bufnr = 1,
          silent = false,
          fn = function() end,
          popup = make_popup(),
        })
        :start()

      vim.wait(100, function()
        return false
      end)
      assert.same({}, notified)

      vim.notify = orig_notify
    end)
  end)

  -- -------------------------------------------------------------------------
  -- Real async.run — correct scheduling context
  -- -------------------------------------------------------------------------

  describe("with real async.run", function()
    it("finally_scheduled_fn is called on the main loop (not inside coroutine)", function()
      -- Use real _async_run; replace _defer to avoid real timer waits.
      async_operation._defer = function() end
      async_operation._get_config = function()
        return { progress = { success_timeout = 2500, failed_timeout = 2500 } }
      end

      local done = false
      local result_ok = nil
      local result_val = nil

      async_operation
        .new({
          bufnr = 1,
          silent = false,
          fn = function()
            return "async_result"
          end,
          popup = make_popup(),
          finally_scheduled_fn = function(ok, result)
            result_ok = ok
            result_val = result
            done = true
          end,
        })
        :start()

      assert.is_true(
        vim.wait(500, function()
          return done
        end),
        "finally_scheduled_fn was not called within 500 ms"
      )

      assert.is_true(result_ok)
      assert.equals("async_result", result_val)
    end)
  end)
end)
