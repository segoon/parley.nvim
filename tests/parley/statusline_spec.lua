local model = require("parley.model")
local read_service = require("parley.services.read")
local statusline = require("parley.statusline")

local SAMPLE_PR = model.new_pr({
  id = "42",
  title = "Add feature",
  state = "open",
  base_branch = "main",
  head_branch = "feature",
  author = "alice",
  url = "https://github.com/owner/repo/pull/42",
  review_status = "approved",
})

describe("parley.statusline", function()
  local saved_get_buffer_state

  before_each(function()
    saved_get_buffer_state = read_service.get_buffer_state
  end)

  after_each(function()
    read_service.get_buffer_state = saved_get_buffer_state
  end)

  it("returns an empty string when the buffer is inactive", function()
    read_service.get_buffer_state = function(_bufnr)
      return nil
    end

    assert.equals("", statusline.component(7))
  end)

  it("formats GitHub PR state and unresolved count", function()
    read_service.get_buffer_state = function(_bufnr)
      return {
        pr = SAMPLE_PR,
        provider = { _cache_provider = "github" },
        discussions = {},
        summary = { unresolved_count = 3 },
      }
    end

    assert.equals("GitHub PR #42 · approved · 3 unresolved", statusline.component(7))
  end)

  it("uses singular unresolved wording for one discussion", function()
    read_service.get_buffer_state = function(_bufnr)
      return {
        pr = SAMPLE_PR,
        provider = { _cache_provider = "github" },
        discussions = {},
        summary = { unresolved_count = 1 },
      }
    end

    assert.equals("GitHub PR #42 · approved · 1 unresolved", statusline.component(7))
  end)

  it("still renders for PR files without local discussions", function()
    read_service.get_buffer_state = function(_bufnr)
      return {
        pr = SAMPLE_PR,
        provider = { _cache_provider = "github" },
        discussions = {},
        summary = { unresolved_count = 0 },
      }
    end

    assert.equals("GitHub PR #42 · approved · 0 unresolved", statusline.component(7))
  end)
end)
