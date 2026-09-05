local config = require("parley.providers.arcanum.config")
local provider = require("parley.providers.arcanum.provider")
describe("Arcanum HTTPS authorities", function()
  it("accepts hostnames, ports, and bracketed IPv6", function()
    for _, host in ipairs({ "arcanum.yandex.net", "localhost:8443", "[::1]", "[2001:db8::1]:443" }) do
      assert.equals(host, config.resolve({ host = host }).host)
    end
  end)
  it("rejects URL components and invalid authorities", function()
    for _, host in ipairs({
      "",
      "https://host",
      "user@host",
      "host/path",
      "host?token=secret",
      "host#x",
      "host name",
      "host:0",
      "host:65536",
      "[:::]",
      "[1::2:]",
      "[abc]",
      "-bad.host",
      "host..name",
    }) do
      assert.has_error(function()
        config.resolve({ host = host })
      end, nil, host)
    end
  end)
  it("validates and normalizes the effective constructor override", function()
    local p = provider.new({
      host = "OVERRIDE.example:8443",
      config = { host = "invalid/path" },
      _auth = {
        read_token = function()
          return nil
        end,
      },
    })
    assert.equals("override.example:8443", p._host)
    assert.has_error(function()
      provider.new({ host = "invalid/path" })
    end)
  end)
end)
