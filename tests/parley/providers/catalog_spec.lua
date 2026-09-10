local catalog = require("parley.providers")

describe("provider catalog", function()
  local saved
  before_each(function()
    saved = catalog._descriptors
  end)
  after_each(function()
    catalog._descriptors = saved
  end)
  it("binds copied configuration for a synthetic descriptor", function()
    local initialized, received, registered = 0, nil, nil
    catalog._descriptors = function()
      return {
        {
          id = "custom",
          name = "Custom",
          defaults = { value = 1 },
          detect = function()
            return {}
          end,
          factory = function(opts, config)
            received = { opts = opts, config = config }
            return {}
          end,
          initialize = function()
            initialized = initialized + 1
          end,
        },
      }
    end
    local config = { custom = { value = 2 } }
    local deps = {
      registry = {
        register = function(spec)
          registered = spec
        end,
      },
      vcs = { register_adapter = function() end, register_detector = function() end },
    }
    catalog.register(deps, config)
    config.custom.value = 3
    registered.factory({ opaque = true })
    assert.equals(2, received.config.value)
    assert.is_true(received.opts.opaque)
    assert.equals(1, initialized)
    local old_factory = registered.factory
    catalog.register(deps, config)
    assert.equals(2, initialized)
    registered.factory({})
    assert.equals(3, received.config.value)
    received.config.value = 100
    registered.factory({})
    assert.equals(3, received.config.value)
    old_factory({})
    assert.equals(2, received.config.value)
    local defaults = catalog.defaults()
    defaults.custom.value = 9
    assert.equals(1, catalog.defaults().custom.value)
  end)
end)
