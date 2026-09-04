local read = require("parley.services.read")
local providers = require("parley.repositories.provider")
local reviews = require("parley.repositories.review")
local contexts = require("parley.repositories.context")

describe("read service presentation state", function()
  local saved = {}
  before_each(function()
    saved = { providers.get, reviews.get, contexts.get }
    reviews.get = function()
      return { pr = { id = "42" } }
    end
    contexts.get = function()
      return nil
    end
  end)
  after_each(function()
    providers.get, reviews.get, contexts.get = unpack(saved)
  end)
  it("exposes provider display metadata in buffer state", function()
    providers.get = function()
      return { provider = { display_name = "Custom Host" } }
    end
    assert.equals("Custom Host", read.get_buffer_state(1).provider_display_name)
    providers.get = function()
      return nil
    end
    assert.is_nil(read.get_buffer_state(1).provider_display_name)
  end)
end)
