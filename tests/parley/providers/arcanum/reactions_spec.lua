local reactions = require("parley.providers.arcanum.reactions")

describe("Arcanum reaction metadata", function()
  it("offers exactly the reaction codes accepted by AI comments", function()
    assert.same({
      { reaction = ":+1:", label = "Like", emoji = "👍" },
      { reaction = ":heart:", label = "Super like", emoji = "❤️" },
      { reaction = ":facepalm:", label = "Not relevant", emoji = "🤦" },
      { reaction = ":confused:", label = "Incorrect", emoji = "😕" },
      { reaction = ":goose:", label = "Too wordy", emoji = "🪿" },
      { reaction = ":thinking:", label = "Inappropriate", emoji = "🤔" },
      { reaction = ":-1:", label = "Other", emoji = "👎" },
    }, reactions.choices(nil, {}, { reactions = {} }))
  end)

  it("preserves unknown codes alongside the supported palette", function()
    assert.same({ label = "raw-code" }, reactions.presentation(nil, "raw-code"))
    local choices = reactions.choices(nil, {}, { reactions = {} })
    assert.equals(7, #choices)
  end)
end)
