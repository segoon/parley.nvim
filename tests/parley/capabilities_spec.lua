local capabilities = require("parley.capabilities")

describe("provider action capabilities", function()
  it("preserves legacy writes but requires explicit resolution support", function()
    for _, action in ipairs({ "post_top_level_comment", "reply", "edit", "delete", "react", "submit_review" }) do
      assert.is_nil(capabilities.reason({}, {}, action))
    end
    assert.is_string(capabilities.reason({}, {}, "resolve"))
    assert.is_string(capabilities.reason({}, {}, "unresolve"))
  end)
  it("fails closed on missing, malformed or failing declarations", function()
    for _, value in ipairs({ {}, { resolve = true }, { resolve = { available = "yes" } } }) do
      assert.is_string(capabilities.reason({
        capabilities = function()
          return value
        end,
      }, {}, "resolve"))
    end
    assert.is_string(capabilities.reason({
      capabilities = function()
        error("broken")
      end,
    }, {}, "resolve"))
  end)
  it("uses provider reasons and allows explicit support", function()
    local p = {
      capabilities = function()
        return { resolve = { available = true }, react = { available = false, reason = "Not implemented" } }
      end,
    }
    assert.is_nil(capabilities.reason(p, {}, "resolve"))
    assert.equals("Not implemented", capabilities.reason(p, {}, "react"))
  end)
end)
