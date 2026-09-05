local diagnostics = require("parley.providers.arcanum.diagnostics")

describe("Arcanum local diagnostics", function()
  local executable, read_token
  before_each(function()
    executable, read_token = diagnostics._executable, diagnostics._read_token
  end)
  after_each(function()
    diagnostics._executable, diagnostics._read_token = executable, read_token
  end)
  it("checks only Arc tools and never includes credential contents", function()
    local calls = {}
    diagnostics._executable = function(tool)
      calls[#calls + 1] = tool
      return 1
    end
    diagnostics._read_token = function()
      return "SECRET"
    end
    local entries = diagnostics.check({ vcs_info = { branch = "remote" }, opts = { login = "alice" } })
    assert.same({ "arc", "curl" }, calls)
    for _, entry in ipairs(entries) do
      assert.equals("ok", entry.level)
      assert.is_nil(entry.message:find("SECRET", 1, true))
    end
  end)
  it("reports missing tools, branch, login, and credentials independently", function()
    diagnostics._executable = function()
      return 0
    end
    diagnostics._read_token = function()
      return nil
    end
    local entries = diagnostics.check({ vcs_info = {}, opts = {} })
    assert.equals(6, #entries)
    assert.equals("ok", entries[1].level)
    assert.equals("error", entries[2].level)
    assert.equals("error", entries[3].level)
    for i = 4, 6 do
      assert.equals("warn", entries[i].level)
    end
  end)
end)
