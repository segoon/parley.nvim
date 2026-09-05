local http = require("parley.http")
local async_tests = require("plenary.async.tests")
local clock_factory = dofile("tests/support/clock.lua")

describe("HTTP lifecycle", function()
  local saved, clock, options, job, results
  before_each(function()
    saved = { curl = http._curl, defer = http._defer }
    clock, results = clock_factory.new(), {}
    http._defer = clock.defer
    job = { killed = 0, stopped = 0 }
    job.handle = {
      is_closing = function()
        return false
      end,
      kill = function(_, signal)
        assert.equals("sigkill", signal)
        job.killed = job.killed + 1
      end,
    }
    job.shutdown = function()
      job.stopped = job.stopped + 1
    end
    http._curl = {
      get = function(_, opts)
        options = opts
        return job
      end,
    }
  end)
  after_each(function()
    http._curl, http._defer = saved.curl, saved.defer
  end)

  --- @return table
  local function start()
    return http.start({ url = "https://example.test", timeout_ms = 200 }, function(r)
      results[#results + 1] = r
    end)
  end

  it("installs on_error and bounds async curl execution", function()
    start()
    assert.equals("function", type(options.on_error))
    assert.same({ "--max-time", "0.2" }, options.raw)
    options.on_error({ exit = 7, message = "connection refused" })
    options.callback({ status = 200, body = "late" })
    clock.advance(200)
    assert.equals(1, #results)
    assert.equals(7, results[1].exit)
    assert.is_false(results[1].ok)
  end)

  it("kills the process and closes handles on cancellation exactly once", function()
    local handle = start()
    handle.cancel()
    handle.cancel()
    options.on_error({ exit = 9 })
    assert.equals(1, job.killed)
    assert.equals(1, job.stopped)
    assert.equals(1, #results)
    assert.is_true(results[1].cancelled)
    assert.is_true(results[1].sent)
  end)

  it("times out even when curl never calls back", function()
    start()
    clock.advance(200)
    assert.is_true(results[1].timed_out)
    assert.equals(1, job.killed)
    options.callback({ status = 200 })
    assert.equals(1, #results)
  end)

  it("reports startup exceptions and malformed responses through completion", function()
    http._curl.get = function()
      error("spawn failed")
    end
    start()
    assert.matches("spawn failed", results[1].err)
    http._curl.get = function(_, opts)
      opts.callback(vim.NIL)
      return job
    end
    start()
    assert.is_false(results[2].ok)
  end)

  it("handles an inline callback before the job handle is returned", function()
    http._curl.get = function(_, opts)
      opts.callback({ status = 200, body = "ok" })
      return job
    end
    local handle = start()
    handle.cancel()
    clock.advance(1000)
    assert.equals(1, #results)
    assert.equals(200, results[1].response.status)
    assert.equals(0, job.killed)
  end)

  async_tests.it("wakes coroutine callers on curl failure", function()
    http._curl.get = function(_, opts)
      vim.schedule(function()
        opts.on_error({ exit = 6, message = "DNS failure" })
      end)
      return job
    end
    local ok, err = pcall(http.request, { url = "https://example.test" })
    assert.is_false(ok)
    assert.matches("DNS failure", err)
  end)
end)
