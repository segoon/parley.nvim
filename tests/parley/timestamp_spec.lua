local timestamp = require("parley.timestamp")

describe("parley.timestamp", function()
  it("corrects UTC Z timestamps before computing relative time", function()
    local formatted = timestamp.format("2026-05-09T09:59:30Z", {
      now = function()
        return 36000
      end,
      date = function(_fmt, epoch)
        assert.equals(35970, epoch)
        return "2026-05-09 12:59:30 (LOCAL)"
      end,
      strptime = function(_fmt, value)
        assert.equals("2026-05-09T09:59:30Z", value)
        return 25170
      end,
      utc_offset = function(epoch)
        assert.equals(25170, epoch)
        return 10800
      end,
    })

    assert.equals("2026-05-09 12:59:30 (LOCAL) (1 min ago)", formatted)
  end)

  it("normalizes fractional-second UTC timestamps before parsing", function()
    local formatted = timestamp.format("2026-05-10T18:54:10.602909Z", {
      now = function()
        return 72000
      end,
      date = function(_fmt, epoch)
        assert.equals(71710, epoch)
        return "2026-05-10 21:54:10 (LOCAL)"
      end,
      strptime = function(_fmt, value)
        assert.equals("2026-05-10T18:54:10Z", value)
        return 60910
      end,
      utc_offset = function(epoch)
        assert.equals(60910, epoch)
        return 10800
      end,
    })

    assert.equals("2026-05-10 21:54:10 (LOCAL) (4 mins ago)", formatted)
  end)

  it("falls back to the raw timestamp when strptime returns 0", function()
    assert.equals(
      "not-a-timestamp",
      timestamp.format("not-a-timestamp", {
        now = function()
          return 0
        end,
        date = function()
          return "unused"
        end,
        strptime = function()
          return 0
        end,
        utc_offset = function()
          return 0
        end,
      })
    )
  end)

  it("falls back to the raw timestamp when parsing returns nil", function()
    assert.equals(
      "not-a-timestamp",
      timestamp.format("not-a-timestamp", {
        now = function()
          return 0
        end,
        date = function()
          return "unused"
        end,
        strptime = function()
          return nil
        end,
        utc_offset = function()
          return 0
        end,
      })
    )
  end)
end)
