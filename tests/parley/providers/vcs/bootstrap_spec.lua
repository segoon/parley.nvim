local vcs = require("parley.vcs")
local bootstrap = require("parley.providers.vcs")

describe("built-in VCS registration", function()
  local saved, detectors
  before_each(function()
    detectors = vcs.registered_detectors()
    saved = {}
    for _, name in ipairs({ "arc", "git" }) do
      local module = name == "arc" and "parley.providers.arcanum.vcs_detector" or "parley.providers.github.vcs_detector"
      saved[module] = package.loaded[module]
      package.loaded[module] = {
        detect = function()
          return { vcs = name, root = "/checkout" }
        end,
      }
    end
    vcs.reset_detectors()
    vcs.reset_adapters()
  end)
  after_each(function()
    for module, value in pairs(saved) do
      package.loaded[module] = value
    end
    package.loaded["parley.providers.arcanum.vcs_detector"] = saved["parley.providers.arcanum.vcs_detector"]
    package.loaded["parley.providers.github.vcs_detector"] = saved["parley.providers.github.vcs_detector"]
    vcs.reset_detectors()
    vcs.reset_adapters()
    for _, detector in ipairs(detectors) do
      vcs.register_detector(detector.name, detector.fn)
    end
  end)

  it("registers both adapters and gives Arc detection precedence", function()
    bootstrap.register(vcs)
    assert.equals("arc", vcs.detect("/checkout/file").vcs)
    local adapters = require("parley.vcs.adapters")
    assert.is_not_nil(adapters.get({ vcs = "arc", root = "/checkout" }))
    assert.is_not_nil(adapters.get({ vcs = "git", root = "/checkout" }))
    assert.equals(2, #vcs.registered_detectors())
  end)
end)
