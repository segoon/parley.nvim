local vcs = require("parley.vcs")
local a = require("plenary.async.tests")

--- @return parley.VcsAdapter
local function adapter()
  return {
    head = function()
      return { "custom", "head" }
    end,
    show = function(rev, path)
      return { "custom", "read", rev, path }
    end,
    status = function(path)
      return { "custom", "status", path }
    end,
    dirty = function(output)
      return output ~= "clean"
    end,
    diff = function(base, head, path)
      return { "custom", "diff", base, head, path }
    end,
  }
end

a.describe("VCS adapter registry", function()
  local saved, calls
  a.before_each(function()
    vcs.reset_adapters()
    saved, calls = vcs._runner, {}
    vcs._runner = function(cmd)
      calls[#calls + 1] = cmd
      assert.equals("custom", cmd[1])
      local outputs = { head = "rev", read = "text", status = "clean", diff = "@@ -1 +1 @@\n" }
      return { code = 0, stdout = outputs[cmd[2]] }
    end
  end)
  a.after_each(function()
    vcs._runner = saved
    vcs.reset_adapters()
  end)

  a.it("dispatches every shared operation through a registered custom VCS", function()
    vcs.register_adapter("custom", adapter())
    local info = { vcs = "custom", root = "/checkout" }
    assert.equals("text", vcs.read_file(info, "rev", "a b"))
    assert.is_true(vcs.check_sync_state(info, "a b", "rev").ok)
    assert.is_true(vcs.check_anchor_in_diff(info, "base", "a b", { start_line = 1 }, "rev").ok)
    assert.same({
      { "custom", "read", "rev", "a b" },
      { "custom", "head" },
      { "custom", "status", "a b" },
      { "custom", "diff", "base", "rev", "a b" },
    }, calls)
  end)

  a.it("has no implicit built-ins and executes nothing for missing adapters", function()
    for _, name in ipairs({ "git", "arc", "unknown" }) do
      local info = { vcs = name, root = "/checkout" }
      assert.is_nil(vcs.read_file(info, "rev", "f"))
      assert.is_false(vcs.check_sync_state(info, "f", "rev").ok)
      assert.is_false(vcs.check_anchor_in_diff(info, "base", "f", { start_line = 1 }).ok)
    end
    assert.equals(0, #calls)
  end)

  a.it("rejects invalid definitions and duplicate names", function()
    assert.has_error(function()
      vcs.register_adapter("", adapter())
    end)
    assert.has_error(function()
      vcs.register_adapter("custom", nil)
    end)
    for _, method in ipairs({ "head", "show", "status", "dirty", "diff" }) do
      local invalid = adapter()
      invalid[method] = "invalid"
      assert.has_error(function()
        vcs.register_adapter("custom", invalid)
      end)
    end
    vcs.register_adapter("custom", adapter())
    assert.has_error(function()
      vcs.register_adapter("custom", adapter())
    end)
  end)

  a.it("reset removes registrations and permits registering again", function()
    vcs.register_adapter("custom", adapter())
    vcs.reset_adapters()
    assert.is_nil(vcs.read_file({ vcs = "custom", root = "/checkout" }, "rev", "f"))
    assert.equals(0, #calls)
    vcs.register_adapter("custom", adapter())
  end)
end)
