local create = require("parley.services.write_operation")
local reviews = require("parley.repositories.review")
local composer = require("parley.ui_states.composer")
local progress = require("parley.ui_states.progress")
local github = require("parley.providers.github.provider")
local transport = require("parley.providers.github.transport")
local texts =
  { running = "running", refreshing = "refreshing", success = "success", failed = "failed", cancelled = "cancelled" }

for _, mode in ipairs({ "submit", "action" }) do
  describe("write operation " .. mode, function()
    local hooks, ops, instance, saved, refreshed, closed, notices
    before_each(function()
      saved = { reviews.refresh, reviews.invalidate, package.loaded["parley.discussion_window"] }
      package.loaded["parley.discussion_window"] = { open_current_line = function() end }
      saved.gh_available, saved.executable, saved.notify = transport._gh_available, transport._executable, vim.notify
      refreshed, closed, notices = 0, 0, {}
      reviews.refresh = function()
        refreshed = refreshed + 1
      end
      reviews.invalidate = function() end
      progress.clear()
      composer.set(1, { draft = "keep me" })
      hooks = {
        _operations = {},
        _next_progress_id = 0,
        _now = function()
          return 1
        end,
        _get_config = function()
          return {}
        end,
        _defer = function() end,
        _notify = function(message)
          notices[#notices + 1] = message
        end,
      }
      instance = {
        set_submitting = function() end,
        set_idle = function() end,
        set_cancel = function(callback)
          instance.cancel = callback
        end,
        close = function()
          closed = closed + 1
        end,
      }
      ops = create(hooks)
    end)
    after_each(function()
      vim.wait(20, function()
        return false
      end)
      reviews.refresh, reviews.invalidate = saved[1], saved[2]
      package.loaded["parley.discussion_window"] = saved[3]
      transport._gh_available, transport._executable, vim.notify = saved.gh_available, saved.executable, saved.notify
      progress.clear()
      composer.clear(1)
    end)
    --- @param starter function
    --- @return boolean
    local function run(starter)
      if mode == "submit" then
        return ops.run_submit(1, instance, starter, "submitting", texts)
      end
      return ops.run_action(1, nil, starter, texts)
    end
    it("preserves uncertain write outcomes in the visible failure message", function()
      local idle
      instance.set_idle = function(message)
        idle = message
      end
      local message = "Check the review before retrying; the change may have been sent."
      run(function(callback)
        callback({ ok = false, uncertain = true, cancelled = true, err = message })
        return { cancel = function() end }
      end)
      if mode == "submit" then
        assert.matches(message, idle, 1, true)
        assert.equals("keep me", composer.get(1).draft)
      else
        assert.equals(message, notices[1])
      end
    end)
    it("allows retry after GitHub detects a missing executable", function()
      transport._gh_available = nil
      transport._executable = function()
        return 0
      end
      vim.notify = function() end
      local spawned = false
      local provider = github.new({
        repository = "owner/repo",
        config = { retry_count = 0 },
        _spawn = function()
          spawned = true
          error("must not spawn")
        end,
      })
      local function starter(callback)
        return provider:begin_reply(
          { write_context = { number = 1, head_sha = "revision" } },
          {},
          { id = "2" },
          { text = "reply" },
          callback
        )
      end
      assert.is_true(run(starter))
      assert.is_nil(hooks._operations[1])
      assert.is_true(run(starter))
      assert.is_nil(hooks._operations[1])
      assert.is_false(spawned)
      assert.equals(2, #notices)
      assert.is_truthy(notices[1]:find("not found", 1, true))
    end)
    it("completes deferred success and refreshes exactly once", function()
      run(function(cb)
        vim.schedule(function()
          cb({ ok = true })
          cb({ ok = true })
        end)
        return { cancel = function() end }
      end)
      assert.is_not_nil(hooks._operations[1])
      assert.is_true(vim.wait(300, function()
        return refreshed == 1 and progress.list()[1].state == "success"
      end))
      assert.is_nil(hooks._operations[1])
      assert.equals(mode == "submit" and 1 or 0, closed)
    end)
    it("completes inline success once without retaining a late handle", function()
      local cancel_count = 0
      run(function(cb)
        cb({ ok = true })
        cb({ ok = false, err = "duplicate" })
        return {
          cancel = function()
            cancel_count = cancel_count + 1
          end,
        }
      end)
      assert.is_nil(hooks._operations[1])
      assert.is_true(vim.wait(300, function()
        return refreshed == 1 and progress.list()[1].state == "success"
      end))
      assert.equals(mode == "submit" and 1 or 0, closed)
      assert.equals(0, cancel_count)
      assert.equals(0, #notices)
    end)
    it("ignores stale callbacks and stale cancellation after retry", function()
      local first, second, cancellations = nil, nil, 0
      run(function(cb)
        first = cb
        return { cancel = function() end }
      end)
      local old_cancel = hooks._operations[1].cancel
      assert.is_false(run(function()
        error("busy starter must not run")
      end))
      first({ ok = false, err = "first failure" })
      run(function(cb)
        second = cb
        return {
          cancel = function()
            cancellations = cancellations + 1
          end,
        }
      end)
      local current = hooks._operations[1]
      first({ ok = true })
      old_cancel()
      assert.equals(current, hooks._operations[1])
      assert.equals(0, cancellations)
      second({ ok = false, err = "second failure" })
      assert.is_nil(hooks._operations[1])
      assert.equals(0, refreshed)
    end)
    for _, case in ipairs({
      {
        name = "starter exception",
        start = function()
          error("startup")
        end,
      },
      {
        name = "missing handle",
        start = function()
          return nil
        end,
      },
      {
        name = "invalid cancel",
        start = function()
          return { cancel = true }
        end,
      },
      {
        name = "missing result",
        start = function(cb)
          cb(nil)
        end,
      },
      {
        name = "nonboolean success",
        start = function(cb)
          cb({ ok = "yes" })
        end,
      },
      {
        name = "invalid cancellation flag",
        start = function(cb)
          cb({ ok = false, cancelled = "yes" })
        end,
      },
      {
        name = "invalid error",
        start = function(cb)
          cb({ ok = false, err = {} })
        end,
      },
    }) do
      it("terminates on " .. case.name, function()
        assert.is_true(run(case.start))
        assert.is_nil(hooks._operations[1])
        assert.equals("failed", progress.list()[1].state)
        assert.equals("keep me", composer.get(1).draft)
        assert.equals(1, #notices)
      end)
    end
    it("keeps inline completion authoritative over a subsequent exception", function()
      run(function(cb)
        cb({ ok = false, err = "first result" })
        error("too late")
      end)
      assert.is_nil(hooks._operations[1])
      assert.same({ "first result" }, notices)
    end)
    it("ignores callbacks after an invalid pending handle", function()
      local callback
      run(function(cb)
        callback = cb
        return {}
      end)
      callback({ ok = true })
      assert.is_nil(hooks._operations[1])
      assert.equals(0, refreshed)
      assert.equals(1, #notices)
    end)
    it("queues early cancellation and forwards it only once", function()
      local cancel_count = 0
      run(function(cb)
        local cancel = hooks._operations[1].cancel
        cancel()
        cancel()
        return {
          cancel = function()
            cancel_count = cancel_count + 1
            cb({ ok = false, cancelled = true })
          end,
        }
      end)
      assert.equals(1, cancel_count)
      assert.is_nil(hooks._operations[1])
      assert.is_true(vim.wait(300, function()
        return refreshed == 1
      end))
      assert.equals("cancelled", progress.list()[1].state)
      assert.equals("keep me", composer.get(1).draft)
    end)
    it("does not cancel a handle returned after inline completion", function()
      local cancelled = false
      run(function(cb)
        hooks._operations[1].cancel()
        cb({ ok = false, err = "finished" })
        return {
          cancel = function()
            cancelled = true
          end,
        }
      end)
      assert.is_false(cancelled)
      assert.is_nil(hooks._operations[1])
    end)
    it("waits for cancellation completion and catches cancellation exceptions", function()
      local count, callback = 0, nil
      run(function(cb)
        callback = cb
        return {
          cancel = function()
            count = count + 1
          end,
        }
      end)
      local cancel = hooks._operations[1].cancel
      cancel()
      cancel()
      assert.equals(1, count)
      assert.is_not_nil(hooks._operations[1])
      callback({ ok = false, cancelled = true })
      run(function()
        return {
          cancel = function()
            error("cancel failed")
          end,
        }
      end)
      hooks._operations[1].cancel()
      assert.is_nil(hooks._operations[1])
      assert.is_truthy(notices[1]:find("cancel failed", 1, true))
    end)
    if mode == "submit" then
      it("binds composer cancellation to the original operation", function()
        local callback
        run(function(cb)
          callback = cb
          return { cancel = function() end }
        end)
        local old_cancel = instance.cancel
        callback({ ok = false, err = "first" })
        local cancelled = false
        run(function()
          return {
            cancel = function()
              cancelled = true
            end,
          }
        end)
        old_cancel()
        assert.is_false(cancelled)
        instance.cancel()
        assert.is_true(cancelled)
      end)
    end
    it("clears immediate failures and permits retry", function()
      local function starter(cb)
        cb({ ok = false, err = "failed" })
        return { cancel = function() end }
      end
      assert.is_true(run(starter))
      assert.is_nil(hooks._operations[1])
      assert.is_true(run(starter))
      assert.equals(2, #notices)
      assert.equals("keep me", composer.get(1).draft)
    end)
  end)
end
