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
    saved, calls = transport.http_start, {}
    transport.http_start = function(_, method, path, body, cb, opts)
      calls[#calls + 1] = { method, path, body, opts }
      cb({ ok = true })
      return { cancel = function() end }
    end
  end)
  after_each(function()
    transport.http_start = saved
  end)
  it("offers common codes and removal of the viewer's other codes", function()
    local choices = p:reaction_choices({}, {
      reactions = {
        { type = ":custom:", viewer_reacted = true },
        { type = ":other:", viewer_reacted = false },
      },
    })
    assert.equals(4, #choices)
    assert.equals(":+1:", choices[1].reaction)
    assert.equals(":custom:", choices[4].reaction)
    assert.is_true(choices[4].remove_only)
  end)
  it("encodes codes and uses PR identity for every comment location", function()
    for _, present in ipairs({ true, false }) do
      local result
      p:begin_set_reaction({ pr = { id = "12" } }, "-42", ":+1:", present, function(r)
        result = r
      end)
      assert.is_true(result.ok)
      local call = calls[#calls]
      assert.equals(present and "PUT" or "DELETE", call[1])
      assert.equals("/v1/plugin/pull-request/12/comment/-42/reaction/%3A%2B1%3A", call[2])
      assert.is_nil(call[3])
      assert.same({ retry_policy = "none" }, call[4])
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
    assert.matches("a%%2Fb%%3F$", calls[1][2])
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
