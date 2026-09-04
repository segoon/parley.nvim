local catalog = require("parley.providers")
local github = require("parley.providers.github.provider")
local arcanum = require("parley.providers.arcanum.provider")
local arc_transport = require("parley.providers.arcanum.transport")
local gh_transport = require("parley.providers.github.transport")
local auth = {
  read_token = function()
    return "token"
  end,
}

describe("provider configuration", function()
  it("copies constructor configuration and preserves zero retries", function()
    for _, entry in ipairs({ { github, gh_transport }, { arcanum, arc_transport } }) do
      local config = { timeout_ms = 123, retry_count = 0 }
      local p = entry[1].new({ repository = "owner/repo", config = config, _auth = auth })
      config.timeout_ms = 456
      local resolved = entry[2].transport_config(p)
      assert.equals(123, resolved.timeout_ms)
      assert.equals(0, resolved.retry_count)
      assert.equals(250, resolved.retry_base_delay_ms)
      assert.equals(2000, resolved.retry_max_delay_ms)
    end
  end)

  it("uses provider-owned defaults for direct construction", function()
    assert.equals(5000, gh_transport.transport_config(github.new({ repository = "owner/repo" })).timeout_ms)
    local p = arcanum.new({ _auth = auth })
    assert.equals(10000, arc_transport.transport_config(p).timeout_ms)
    assert.equals("https://arcanum.yandex.net/api/v1/test", arc_transport.api_url(p, "/v1/test"))
  end)

  it("prefers an explicit Arcanum host over configured host", function()
    local p = arcanum.new({ host = "explicit.example", config = { host = "configured.example" }, _auth = auth })
    assert.equals("https://explicit.example/api/v1/test", arc_transport.api_url(p, "/v1/test"))
  end)

  it("binds configured hosts and transport settings through registered factories", function()
    local registrations, detectors = {}, {}
    local deps = {
      registry = {
        register = function(spec)
          registrations[#registrations + 1] = spec
        end,
      },
      vcs = {
        register_adapter = function() end,
        register_detector = function(name)
          detectors[#detectors + 1] = name
        end,
      },
    }
    local config =
      { arcanum = { host = "configured.example", timeout_ms = 123, retry_count = 0 }, github = { timeout_ms = 321 } }
    catalog.register(deps, config)
    assert.same({ "arc", "git" }, detectors)
    assert.equals("GitHub", registrations[1].name)
    assert.equals("Arcanum", registrations[2].name)
    local old_factory = registrations[2].factory
    local p = old_factory({ login = "alice", _auth = auth })
    assert.equals("https://configured.example/api/v1/test", arc_transport.api_url(p, "/v1/test"))
    assert.equals("configured.example", p:cache_identity().host)
    assert.equals(123, arc_transport.transport_config(p).timeout_ms)
    assert.equals(
      321,
      gh_transport.transport_config(registrations[1].factory({ repository = "owner/repo" })).timeout_ms
    )
    config.arcanum.host = "next.example"
    config.arcanum.timeout_ms = 456
    catalog.register(deps, config)
    assert.equals("configured.example", old_factory({ _auth = auth }):cache_identity().host)
    assert.equals(123, arc_transport.transport_config(p).timeout_ms)
    local next_provider = registrations[4].factory({ _auth = auth })
    assert.equals("next.example", next_provider:cache_identity().host)
    assert.equals(456, arc_transport.transport_config(next_provider).timeout_ms)
  end)
end)
