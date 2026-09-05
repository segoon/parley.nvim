local diagnostics = require("parley.providers.github.diagnostics")

describe("GitHub local diagnostics", function()
  local executable, read_token
  before_each(function()
    executable, read_token = diagnostics._executable, diagnostics._read_token
  end)
  after_each(function()
    diagnostics._executable, diagnostics._read_token = executable, read_token
  end)
  it("uses the detected host and checks only GitHub tools", function()
    local calls = {}
    diagnostics._executable = function(tool)
      calls[#calls + 1] = tool
      return 1
    end
    diagnostics._read_token = function(host)
      assert.equals("example.test", host)
      return "SECRET"
    end
    local entries = diagnostics.check({ vcs_info = { branch = "feature" }, opts = { host = "example.test" } })
    assert.same({ "git", "gh" }, calls)
    for _, entry in ipairs(entries) do
      assert.equals("ok", entry.level)
      assert.is_nil(entry.message:find("SECRET", 1, true))
    end
  end)
  it("reports missing CLI and credentials without rejecting detached HEAD", function()
    diagnostics._executable = function(tool)
      return tool == "git" and 1 or 0
    end
    diagnostics._read_token = function()
      return nil
    end
    local entries = diagnostics.check({ vcs_info = {}, opts = { host = "example.test" } })
    assert.equals("error", entries[2].level)
    assert.equals("info", entries[3].level)
    assert.equals("warn", entries[4].level)
  end)
end)
