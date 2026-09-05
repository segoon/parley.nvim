--- Tests for parley.vcs — VCS detection dispatcher.
--- Run via: make test

local a = require("plenary.async").tests
local vcs = require("parley.vcs")

local original_detectors

-- ---------------------------------------------------------------------------
-- Suite: dispatcher (register_detector / detect)
-- ---------------------------------------------------------------------------

a.describe("parley.vcs dispatcher", function()
  a.before_each(function()
    original_detectors = vcs.registered_detectors()
    vcs.reset_detectors()
  end)

  a.after_each(function()
    vcs.reset_detectors()
    for _, d in ipairs(original_detectors) do
      vcs.register_detector(d.name, d.fn)
    end
  end)

  a.it("returns nil when no detectors are registered", function()
    local result = vcs.detect("/some/path/file.lua")
    assert.is_nil(result)
  end)

  a.it("calls registered detector with the path", function()
    local received_path = nil
    vcs.register_detector("test", function(path)
      received_path = path
      return nil
    end)

    vcs.detect("/my/file.lua")

    assert.equals("/my/file.lua", received_path)
  end)

  a.it("returns first non-nil result", function()
    vcs.register_detector("first", function(_path)
      return nil
    end)
    vcs.register_detector("second", function(_path)
      return { vcs = "git", root = "/repo", branch = "main", remote_url = nil }
    end)
    vcs.register_detector("third", function(_path)
      return { vcs = "other", root = "/other", branch = nil, remote_url = nil }
    end)

    local result = vcs.detect("/some/file.lua")

    assert.equals("git", result.vcs)
  end)

  a.it("stops at first non-nil result (does not call later detectors)", function()
    local third_called = false
    vcs.register_detector("first", function(_path)
      return { vcs = "git", root = "/repo", branch = "main", remote_url = nil }
    end)
    vcs.register_detector("second", function(_path)
      third_called = true
      return nil
    end)

    vcs.detect("/file.lua")

    assert.is_false(third_called)
  end)

  a.it("tries detectors in registration order", function()
    local order = {}
    vcs.register_detector("alpha", function(_path)
      table.insert(order, "alpha")
      return nil
    end)
    vcs.register_detector("beta", function(_path)
      table.insert(order, "beta")
      return nil
    end)
    vcs.register_detector("gamma", function(_path)
      table.insert(order, "gamma")
      return nil
    end)

    vcs.detect("/file.lua")

    assert.same({ "alpha", "beta", "gamma" }, order)
  end)

  a.it("reset_detectors removes all detectors", function()
    vcs.register_detector("test", function(_path)
      return { vcs = "test", root = "/", branch = nil, remote_url = nil }
    end)
    vcs.reset_detectors()

    local result = vcs.detect("/file.lua")

    assert.is_nil(result)
  end)

  a.it("register_detector raises for empty name", function()
    assert.has_error(function()
      vcs.register_detector("", function() end)
    end)
  end)

  a.it("register_detector raises for non-function fn", function()
    assert.has_error(function()
      vcs.register_detector("test", "not-a-function")
    end)
  end)

  a.it("registered_detectors returns a copy in order", function()
    vcs.register_detector("a", function() end)
    vcs.register_detector("b", function() end)

    local detectors = vcs.registered_detectors()

    assert.equals(2, #detectors)
    assert.equals("a", detectors[1].name)
    assert.equals("b", detectors[2].name)
  end)
end)
