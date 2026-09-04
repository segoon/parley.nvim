local reactions = require("parley.providers.github.reactions")

describe("GitHub reaction metadata", function()
  it("owns the existing ordered catalog and returns independent choices", function()
    local choices = reactions.choices()
    assert.same({ "+1", "-1", "laugh", "confused", "heart", "hooray", "rocket", "eyes" }, reactions.keys())
    assert.equals("👍", choices[1].emoji)
    assert.equals("❤️", choices[5].emoji)
    choices[1].reaction = "changed"
    assert.equals("+1", reactions.choices()[1].reaction)
    assert.is_false(reactions.supports("unknown"))
    assert.same({ label = "unknown" }, reactions.presentation(nil, "unknown"))
  end)
end)
