local read = require("parley.services.read")
local contexts = require("parley.repositories.context")
local providers = require("parley.repositories.provider")
local reviews = require("parley.repositories.review")
local operation = require("parley.async_operation")
local progress = require("parley.ui_states.progress")

describe("read completion and quiet background failures", function()
  local saved, buf, notices, results, fetches
  before_each(function()
    buf = vim.api.nvim_create_buf(false, true)
    saved = {
      contexts.refresh,
      providers.refresh,
      providers.get,
      reviews.refresh,
      reviews.make_key,
      reviews.has_review,
      read._notify,
      operation.new,
    }
    notices, results, fetches = {}, {}, 0
    contexts.refresh = function()
      return { kind = "regular", rel_path = "f", vcs_info = { branch = "feature" } }
    end
    providers.refresh = function()
      return {}
    end
    -- Quiet polling must not even request a progress label.
    providers.get = function()
      return { provider = {
        progress_label = function()
          error("popup requested")
        end,
      } }
    end
    reviews.make_key = function()
      return "key"
    end
    reviews.has_review = function()
      return true
    end
    reviews.refresh = function(_, opts)
      fetches = fetches + 1
      assert.is_true(opts.background)
      assert.is_true(opts.force)
      return { status = "error", error = "remote failure" }
    end
    read._notify = function(message)
      notices[#notices + 1] = message
    end
    progress.clear()
  end)
  after_each(function()
    contexts.refresh, providers.refresh, providers.get, reviews.refresh = saved[1], saved[2], saved[3], saved[4]
    reviews.make_key, reviews.has_review, read._notify, operation.new = saved[5], saved[6], saved[7], saved[8]
    read.clear_buffer_state(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
    progress.clear()
  end)
  local function run()
    read.refresh_async(buf, { background = true }, function(snapshot)
      results[#results + 1] = { snapshot = snapshot }
    end)
    assert.is_true(vim.wait(300, function()
      return #results == 1
    end))
    assert.is_false(read.is_refreshing(buf))
    assert.same({}, notices)
    assert.same({}, progress.list())
  end
  it("finishes after unsupported or missing branch contexts", function()
    contexts.refresh = function()
      return nil
    end
    run()
    assert.equals(0, fetches)
  end)
  it("finishes after a context exception", function()
    contexts.refresh = function()
      error("context failure")
    end
    run()
  end)
  it("finishes quietly after provider preparation fails", function()
    providers.refresh = function()
      error("private provider failure")
    end
    run()
    assert.equals(0, fetches)
  end)
  it("completes quiet remote failures without a popup", function()
    run()
    assert.equals(1, fetches)
    assert.equals("error", results[1].snapshot.status)
  end)
  it("finishes after operation construction throws", function()
    operation.new = function()
      error("startup failure")
    end
    run()
  end)
  it("tracks activity through asynchronous fetch completion", function()
    local complete
    operation.new = function(opts)
      complete = opts.finally_scheduled_fn
      return { start = function() end }
    end
    read.refresh_async(buf, { background = true }, function()
      results[#results + 1] = true
    end)
    assert.is_true(read.is_refreshing(buf))
    complete(false)
    complete(false)
    assert.is_true(vim.wait(300, function()
      return #results == 1
    end))
    assert.is_false(read.is_refreshing(buf))
  end)
end)
