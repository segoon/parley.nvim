local provider = require("parley.providers.arcanum.provider")
local transport = require("parley.providers.arcanum.transport")
describe("Arcanum desired reaction state", function()
  local p, saved, calls
  before_each(function()
    p = provider.new({ _auth = {
      read_token = function()
        return "token"
      end,
    } })
    dofile("tests/support/arcanum_session.lua")(p)
    saved, calls = transport.request_start, {}
    transport.request_start = function(_, request, cb)
      calls[#calls + 1] = request
      cb({ ok = true })
      return { cancel = function() end }
    end
  end)
  after_each(function()
    transport.request_start = saved
  end)
  it("offers supported codes and removal of the viewer's other codes", function()
    local choices = p:reaction_choices({}, {
      reactions = {
        { type = ":custom:", viewer_reacted = true },
        { type = ":other:", viewer_reacted = false },
      },
    })
    assert.equals(8, #choices)
    assert.equals(":+1:", choices[1].reaction)
    assert.equals(":custom:", choices[8].reaction)
    assert.is_true(choices[8].remove_only)
  end)
  it("encodes codes and uses PR identity for every comment location", function()
    for _, present in ipairs({ true, false }) do
      local result
      p:begin_set_reaction({ pr = { id = "12" } }, "-42", ":+1:", present, function(r)
        result = r
      end)
      assert.is_true(result.ok)
      local call = calls[#calls]
      assert.equals("cli", call.kind)
      assert.equals(present and "add-reaction" or "remove-reaction", call.args[2])
      assert.equals("-42", call.args[6])
      assert.equals(":+1:", call.args[8])
      assert.equals("none", call.retry_policy)
    end
  end)
  it("allows removing an opaque code but refuses adding it", function()
    local result
    p:begin_set_reaction({ pr = { id = "12" } }, "42", "a/b?", true, function(r)
      result = r
    end)
    assert.is_false(result.ok)
    assert.equals(0, #calls)
    p:begin_set_reaction({ pr = { id = "12" } }, "42", "a/b?", false, function(r)
      result = r
    end)
    assert.is_true(result.ok)
    assert.equals("a/b?", calls[1].args[8])
  end)
  it("rejects changed credentials before HTTP", function()
    p._auth.read_token = function()
      return "changed"
    end
    local result
    p:begin_set_reaction({ pr = { id = "12" } }, "42", ":heart:", true, function(r)
      result = r
    end)
    assert.is_false(result.ok)
    assert.equals(0, #calls)
  end)
end)
