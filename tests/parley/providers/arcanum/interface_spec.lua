local arcanum = require("parley.providers.arcanum.provider")
local provider_mod = require("parley.provider")

describe("parley.providers.arcanum.provider — interface", function()
  it("satisfies parley.Provider interface", function()
    local p = arcanum.new({
      _auth = {
        read_token = function()
          return "token", nil
        end,
        read_token_async = function()
          return "token", nil
        end,
      },
      _sleep = function(_ms) end,
      _defer = function(cb, _ms)
        cb()
        return nil
      end,
    })

    assert.is_true(provider_mod.validate(p))
  end)
end)

-- ---------------------------------------------------------------------------
-- Suite: detect
-- ---------------------------------------------------------------------------

describe("parley.providers.arcanum.provider — detect", function()
  it("returns opts for vcs='arc'", function()
    local vcs_info = { vcs = "arc", root = "/arc", branch = "users/alice/feat", remote_url = "arc://alice" }
    local opts = arcanum.detect(vcs_info)
    assert.is_not_nil(opts)
  end)

  it("returns nil for vcs='git'", function()
    local vcs_info = { vcs = "git", root = "/repo", branch = "main", remote_url = "https://github.com/org/repo" }
    local opts = arcanum.detect(vcs_info)
    assert.is_nil(opts)
  end)

  it("returns nil for non-table vcs_info", function()
    assert.is_nil(arcanum.detect(nil))
    assert.is_nil(arcanum.detect("string"))
  end)

  it("extracts remote branch id from vcs_info", function()
    local vcs_info = {
      vcs = "arc",
      root = "/arc",
      branch = "users/alice/my-feature",
      remote_url = "arc://alice",
    }
    local opts = arcanum.detect(vcs_info)
    assert.equals("users/alice/my-feature", opts.branch)
  end)

  it("extracts login from remote_url arc:// scheme", function()
    local vcs_info = {
      vcs = "arc",
      root = "/arc",
      branch = "users/bob/feat",
      remote_url = "arc://bob",
    }
    local opts = arcanum.detect(vcs_info)
    assert.equals("bob", opts.login)
  end)

  it("returns nil login when remote_url is nil", function()
    local vcs_info = { vcs = "arc", root = "/arc", branch = "trunk", remote_url = nil }
    local opts = arcanum.detect(vcs_info)
    assert.is_nil(opts.login)
  end)
end)
