local periodic = require("parley.periodic_refresh")
local clock_factory = dofile("tests/support/clock.lua")

describe("periodic visible review refresh", function()
  local saved, clock, calls, candidates, busy, complete
  before_each(function()
    saved = { periodic._defer, periodic._candidates, periodic._eligible, periodic._refresh }
    clock, calls, busy = clock_factory.new(), {}, {}
    candidates = { { bufnr = 1, key = "a" }, { bufnr = 2, key = "b" } }
    periodic._defer = clock.defer
    periodic._candidates = function()
      return candidates
    end
    periodic._eligible = function(item)
      return not busy[item.key]
    end
    periodic._refresh = function(buf, opts, cb)
      calls[#calls + 1] = { buf = buf, opts = opts }
      complete = cb
    end
  end)
  after_each(function()
    periodic.stop()
    periodic._defer, periodic._candidates, periodic._eligible, periodic._refresh = unpack(saved)
  end)
  it("waits a full interval and serializes rounds without accumulating ticks", function()
    periodic.setup(2)
    clock.advance(1999)
    assert.equals(0, #calls)
    clock.advance(1)
    assert.equals(1, #calls)
    assert.same({ force = true, background = true, notify_errors = false, expected_key = "a" }, calls[1].opts)
    clock.advance(20000)
    assert.equals(1, #calls)
    complete()
    assert.equals(2, #calls)
    complete()
    clock.advance(1999)
    assert.equals(2, #calls)
    clock.advance(1)
    assert.equals(3, #calls)
  end)
  it("pauses on focus loss and ignores callbacks from an obsolete round", function()
    periodic.setup(1)
    clock.advance(1000)
    local old = complete
    periodic.focus(false)
    clock.advance(5000)
    old()
    assert.equals(1, #calls)
    periodic.focus(true)
    clock.advance(999)
    assert.equals(1, #calls)
    clock.advance(1)
    assert.equals(2, #calls)
    old()
    assert.equals(2, #calls)
  end)
  it("replaces timers and disables polling cleanly", function()
    periodic.setup(1)
    local obsolete = clock.timers[1].callback
    periodic.setup(2)
    obsolete()
    clock.advance(1000)
    assert.equals(0, #calls)
    periodic.setup(0)
    clock.advance(10000)
    assert.equals(0, #calls)
  end)
  it("skips busy or no-longer-visible reviews and retries after failures", function()
    periodic.setup(1)
    clock.advance(1000)
    busy.b = true
    complete({ status = "error" })
    assert.equals(1, #calls)
    clock.advance(1000)
    assert.equals(2, #calls)
  end)
  it("recovers from startup exceptions and ignores duplicate completions", function()
    periodic._refresh = function(buf, _, cb)
      calls[#calls + 1] = buf
      if buf == 1 then
        error("startup failure")
      end
      complete = cb
    end
    periodic.setup(1)
    clock.advance(1000)
    assert.same({ 1, 2 }, calls)
    complete()
    complete()
    clock.advance(1000)
    assert.same({ 1, 2, 1, 2 }, calls)
  end)
  it("validates intervals before replacing the existing scheduler", function()
    periodic.setup(1)
    for _, value in ipairs({ -1, 0.5, "300", false, math.huge, 0 / 0, 1e20 }) do
      assert.has_error(function()
        periodic.setup(value)
      end)
    end
    clock.advance(1000)
    assert.equals(1, #calls)
  end)
  it("shutdown cannot be restarted by focus or late completions", function()
    periodic.setup(1)
    clock.advance(1000)
    periodic.stop()
    complete()
    periodic.focus(false)
    periodic.focus(true)
    clock.advance(10000)
    assert.equals(1, #calls)
  end)
end)
