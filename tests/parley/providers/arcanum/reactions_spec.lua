local reactions = require("parley.providers.arcanum.reactions")

describe("Arcanum reaction metadata", function()
  it("preserves unknown codes alongside the common palette", function()
    assert.same({ label = "raw-code" }, reactions.presentation(nil, "raw-code"))
    local choices = reactions.choices(nil, {}, { reactions = {} })
    assert.equals(3, #choices)
  end)
end)
