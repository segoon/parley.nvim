local reactions = require("parley.reactions")

describe("provider-owned reactions", function()
  local saved, provider, review
  before_each(function()
    saved = reactions.context
    provider = {
      reaction_choices = function()
        return { { reaction = "custom", label = "Custom", emoji = "X" } }
      end,
      reaction_presentation = function(_, code)
        return { label = code, emoji = "X" }
      end,
    }
    review = { pr = { id = "r" }, head_sha = "rev" }
    reactions.context = function()
      return { provider = provider, review = review }
    end
  end)
  after_each(function()
    reactions.context = saved
  end)
  it("merges provider choices with counts using opaque identifiers", function()
    local items =
      reactions.items(provider, review, { reactions = { { type = "custom", count = 2, viewer_reacted = true } } })
    assert.same({ { reaction = "custom", label = "Custom", emoji = "X", count = 2, viewer_reacted = true } }, items)
    assert.equals("X", reactions.presentation(1)("custom").emoji)
  end)
  it("falls back to raw codes and no choices for old providers", function()
    provider = {}
    assert.equals("raw", reactions.presentation(1)("raw").label)
    assert.same({}, reactions.items(provider, review, { reactions = {} }))
  end)
  it("does not open a picker for unavailable mutations", function()
    provider.reaction_choices = function()
      return {}, "Unavailable here"
    end
    local message
    assert.is_false(reactions.select(1, nil, { id = "c" }, function()
      error("must not open")
    end, function(text)
      message = text
    end))
    assert.equals("Unavailable here", message)
  end)
  it("cancels quietly and rejects a changed picker context before submission", function()
    local callback, notices = nil, {}
    assert.is_true(reactions.select(1, 3, { id = "c" }, function(_, cb)
      callback = cb
    end, function(message)
      notices[#notices + 1] = message
    end))
    callback(nil)
    assert.equals(0, #notices)
    provider = {}
    callback({ reaction = "custom" })
    assert.equals(1, #notices)
    assert.is_truthy(notices[1]:find("context changed", 1, true))
  end)

  it("rejects stale context and choices removed after opening", function()
    local expected = reactions.capture(1)
    assert.is_nil(reactions.validate(1, { id = "c" }, "custom", expected))
    review = { pr = { id = "other" }, head_sha = "rev" }
    assert.is_not_nil(reactions.validate(1, { id = "c" }, "custom", expected))
    expected = reactions.capture(1)
    provider.reaction_choices = function()
      return {}
    end
    assert.is_not_nil(reactions.validate(1, { id = "c" }, "custom", expected))
  end)
end)
