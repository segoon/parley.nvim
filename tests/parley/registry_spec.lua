--- Tests for parley.registry — provider registry.
--- Run via: make test

local registry = require("parley.registry")
local mock_provider = require("parley.mock_provider")
local provider = require("parley.provider")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- A stable VcsInfo to feed registry.resolve in tests that don't care about
--- the value.
--- @type parley.VcsInfo
local SAMPLE_VCS = {
  vcs = "git",
  root = "/repo",
  branch = "main",
  remote_url = "git@example.com:owner/repo.git",
}

--- Return a ProviderSpec whose detect either returns the given opts table
--- on every call (match) or returns nil (miss).
---
---@param name string
---@param match_opts table|nil  non-nil = always match with this opts; nil = never match
---@param factory fun(opts: table): table
---@return parley.ProviderSpec
local function make_spec(name, match_opts, factory)
  return {
    name = name,
    detect = function(_vcs)
      return match_opts
    end,
    factory = factory,
  }
end

--- Factory that creates a valid mock provider (ignores opts).
---@return table
local function valid_factory(_opts)
  return mock_provider.new({})
end

--- Factory that returns a non-provider table (missing methods).
---@return table
local function invalid_factory(_opts)
  return { name = "broken" }
end

-- ---------------------------------------------------------------------------
-- resolve — no registrations / no match
-- ---------------------------------------------------------------------------

describe("parley.registry resolve", function()
  before_each(function()
    registry.reset()
  end)

  it("validates optional health callbacks", function()
    local spec = make_spec("Custom", nil, valid_factory)
    spec.health = "invalid"
    assert.has_error(function()
      registry.register(spec)
    end)
    spec.health = function()
      return {}
    end
    registry.register(spec)
    assert.equals(spec.health, registry.registered()[1].health)
  end)

  it("returns nil when no specs are registered", function()
    assert.is_nil(registry.resolve(SAMPLE_VCS))
  end)

  it("returns nil when detect returns nil for the given vcs_info", function()
    registry.register(make_spec("NoMatch", nil, valid_factory))
    assert.is_nil(registry.resolve(SAMPLE_VCS))
  end)

  it("returns nil when all registered specs fail to match", function()
    registry.register(make_spec("A", nil, valid_factory))
    registry.register(make_spec("B", nil, valid_factory))
    assert.is_nil(registry.resolve(SAMPLE_VCS))
  end)

  -- -------------------------------------------------------------------------
  -- resolve — successful match
  -- -------------------------------------------------------------------------

  it("returns a valid provider when detect returns an opts table", function()
    registry.register(make_spec("Match", { token = "x" }, valid_factory))
    local p = registry.resolve(SAMPLE_VCS)
    assert.is_not_nil(p)
    assert.is_true(provider.validate(p))
  end)

  it("forwards detect's return value as the factory opts argument", function()
    local received_opts = nil
    local opts_from_detect = { owner = "alice", repo = "thing" }
    local spec = {
      name = "OptsCapture",
      detect = function(_vcs)
        return opts_from_detect
      end,
      factory = function(opts)
        received_opts = opts
        return mock_provider.new({})
      end,
    }
    registry.register(spec)
    registry.resolve(SAMPLE_VCS)
    assert.same(opts_from_detect, received_opts)
  end)

  it("rejects providers without target validation", function()
    registry.register(make_spec("MissingValidation", {}, function()
      local p = mock_provider.new({})
      p.validate_comment_target = nil
      return p
    end))
    assert.has_error(function()
      registry.resolve(SAMPLE_VCS)
    end)
  end)

  it("rejects provider instances without display metadata", function()
    registry.register(make_spec("MissingName", {}, function()
      local p = mock_provider.new({})
      p.display_name = nil
      return p
    end))
    local ok, err = pcall(registry.resolve, SAMPLE_VCS)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("MissingName", 1, true))
    assert.is_truthy(tostring(err):find("display_name", 1, true))
  end)

  it("detect receives the exact vcs_info passed to resolve", function()
    local received = nil
    local spec = {
      name = "VcsCapture",
      detect = function(vcs_info)
        received = vcs_info
        return { ok = true }
      end,
      factory = valid_factory,
    }
    registry.register(spec)
    registry.resolve(SAMPLE_VCS)
    assert.same(SAMPLE_VCS, received)
  end)

  -- -------------------------------------------------------------------------
  -- resolve — ordering / first-match wins
  -- -------------------------------------------------------------------------

  it("uses the first matching spec when multiple specs match", function()
    local called = {}
    local spec_a = {
      name = "First",
      detect = function(_)
        return { from = "First" }
      end,
      factory = function(_)
        table.insert(called, "First")
        return mock_provider.new({})
      end,
    }
    local spec_b = {
      name = "Second",
      detect = function(_)
        return { from = "Second" }
      end,
      factory = function(_)
        table.insert(called, "Second")
        return mock_provider.new({})
      end,
    }
    registry.register(spec_a)
    registry.register(spec_b)
    registry.resolve(SAMPLE_VCS)
    assert.same({ "First" }, called)
  end)

  it("tries subsequent specs when the first does not match", function()
    local called = {}
    local spec_a = {
      name = "NoMatch",
      detect = function(_)
        return nil
      end,
      factory = function(_)
        table.insert(called, "NoMatch")
        return mock_provider.new({})
      end,
    }
    local spec_b = {
      name = "Match",
      detect = function(_)
        return { ok = true }
      end,
      factory = function(_)
        table.insert(called, "Match")
        return mock_provider.new({})
      end,
    }
    registry.register(spec_a)
    registry.register(spec_b)
    local p = registry.resolve(SAMPLE_VCS)
    assert.same({ "Match" }, called)
    assert.is_not_nil(p)
  end)

  -- -------------------------------------------------------------------------
  -- resolve — invalid factory result
  -- -------------------------------------------------------------------------

  it("raises an error when the factory returns an invalid provider", function()
    registry.register(make_spec("Bad", { ok = true }, invalid_factory))
    assert.has_error(function()
      registry.resolve(SAMPLE_VCS)
    end)
  end)

  it("error message includes the spec name when factory is invalid", function()
    registry.register(make_spec("BadProvider", { ok = true }, invalid_factory))
    local ok, err = pcall(function()
      registry.resolve(SAMPLE_VCS)
    end)
    assert.is_false(ok)
    assert.is_not_nil(err:find("BadProvider"))
  end)

  it("raises when detect returns a non-table, non-nil value", function()
    registry.register({
      name = "BadDetect",
      detect = function(_)
        return true
      end,
      factory = valid_factory,
    })
    assert.has_error(function()
      registry.resolve(SAMPLE_VCS)
    end)
  end)

  -- -------------------------------------------------------------------------
  -- resolve — registration is not consumed
  -- -------------------------------------------------------------------------

  it("a registration survives multiple resolve calls", function()
    registry.register(make_spec("Persistent", { ok = true }, valid_factory))
    local p1 = registry.resolve(SAMPLE_VCS)
    local p2 = registry.resolve(SAMPLE_VCS)
    assert.is_not_nil(p1)
    assert.is_not_nil(p2)
  end)
end)

-- ---------------------------------------------------------------------------
-- register / registered
-- ---------------------------------------------------------------------------

describe("parley.registry register", function()
  before_each(function()
    registry.reset()
  end)

  it("registered() returns an empty list when nothing is registered", function()
    assert.same({}, registry.registered())
  end)

  it("registered() returns all specs in registration order", function()
    local a = make_spec("A", { ok = true }, valid_factory)
    local b = make_spec("B", nil, valid_factory)
    registry.register(a)
    registry.register(b)
    local list = registry.registered()
    assert.equals(2, #list)
    assert.equals("A", list[1].name)
    assert.equals("B", list[2].name)
  end)

  it("registered() returns a copy — mutations do not affect internal state", function()
    local a = make_spec("A", { ok = true }, valid_factory)
    registry.register(a)
    local list = registry.registered()
    list[1] = nil
    assert.equals(1, #registry.registered())
  end)
end)

-- ---------------------------------------------------------------------------
-- reset
-- ---------------------------------------------------------------------------

describe("parley.registry reset", function()
  before_each(function()
    registry.reset()
  end)

  it("clears all registrations", function()
    registry.register(make_spec("X", { ok = true }, valid_factory))
    registry.reset()
    assert.same({}, registry.registered())
  end)

  it("resolve returns nil after reset even if a spec was registered before", function()
    registry.register(make_spec("X", { ok = true }, valid_factory))
    registry.reset()
    assert.is_nil(registry.resolve(SAMPLE_VCS))
  end)
end)
