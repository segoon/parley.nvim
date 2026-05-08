--- Tests for parley.registry — provider registry.
--- Run via: make test

local registry = require("parley.registry")
local mock_provider = require("parley.mock_provider")
local provider = require("parley.provider")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Return a ProviderSpec whose detect always returns `should_match`.
---@param name string
---@param should_match boolean
---@param factory fun(opts: table): table
---@return parley.ProviderSpec
local function make_spec(name, should_match, factory)
  return {
    name = name,
    detect = function(_path)
      return should_match
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

  it("returns nil when no specs are registered", function()
    assert.is_nil(registry.resolve("/any/path", {}))
  end)

  it("returns nil when detect returns false for the given path", function()
    registry.register(make_spec("NoMatch", false, valid_factory))
    assert.is_nil(registry.resolve("/some/path", {}))
  end)

  it("returns nil when all registered specs fail to match", function()
    registry.register(make_spec("A", false, valid_factory))
    registry.register(make_spec("B", false, valid_factory))
    assert.is_nil(registry.resolve("/some/path", {}))
  end)

  -- -------------------------------------------------------------------------
  -- resolve — successful match
  -- -------------------------------------------------------------------------

  it("returns a valid provider when detect returns true", function()
    registry.register(make_spec("Match", true, valid_factory))
    local p = registry.resolve("/any/path", {})
    assert.is_not_nil(p)
    assert.is_true(provider.validate(p))
  end)

  it("forwards opts to the factory", function()
    local received_opts = nil
    local spec = {
      name = "OptsCapture",
      detect = function(_)
        return true
      end,
      factory = function(opts)
        received_opts = opts
        return mock_provider.new({})
      end,
    }
    local opts = { token = "secret" }
    registry.register(spec)
    registry.resolve("/path", opts)
    assert.same(opts, received_opts)
  end)

  it("detect receives the exact path passed to resolve", function()
    local received_path = nil
    local spec = {
      name = "PathCapture",
      detect = function(path)
        received_path = path
        return true
      end,
      factory = valid_factory,
    }
    registry.register(spec)
    registry.resolve("/exact/buffer/path.lua", {})
    assert.equals("/exact/buffer/path.lua", received_path)
  end)

  -- -------------------------------------------------------------------------
  -- resolve — ordering / first-match wins
  -- -------------------------------------------------------------------------

  it("uses the first matching spec when multiple specs match", function()
    local called = {}
    local spec_a = {
      name = "First",
      detect = function(_)
        return true
      end,
      factory = function(_)
        table.insert(called, "First")
        return mock_provider.new({})
      end,
    }
    local spec_b = {
      name = "Second",
      detect = function(_)
        return true
      end,
      factory = function(_)
        table.insert(called, "Second")
        return mock_provider.new({})
      end,
    }
    registry.register(spec_a)
    registry.register(spec_b)
    registry.resolve("/path", {})
    assert.same({ "First" }, called)
  end)

  it("tries subsequent specs when the first does not match", function()
    local called = {}
    local spec_a = {
      name = "NoMatch",
      detect = function(_)
        return false
      end,
      factory = function(_)
        table.insert(called, "NoMatch")
        return mock_provider.new({})
      end,
    }
    local spec_b = {
      name = "Match",
      detect = function(_)
        return true
      end,
      factory = function(_)
        table.insert(called, "Match")
        return mock_provider.new({})
      end,
    }
    registry.register(spec_a)
    registry.register(spec_b)
    local p = registry.resolve("/path", {})
    assert.same({ "Match" }, called)
    assert.is_not_nil(p)
  end)

  -- -------------------------------------------------------------------------
  -- resolve — invalid factory result
  -- -------------------------------------------------------------------------

  it("raises an error when the factory returns an invalid provider", function()
    registry.register(make_spec("Bad", true, invalid_factory))
    assert.has_error(function()
      registry.resolve("/path", {})
    end)
  end)

  it("error message includes the spec name when factory is invalid", function()
    registry.register(make_spec("BadProvider", true, invalid_factory))
    local ok, err = pcall(function()
      registry.resolve("/path", {})
    end)
    assert.is_false(ok)
    assert.is_not_nil(err:find("BadProvider"))
  end)

  -- -------------------------------------------------------------------------
  -- resolve — registration is not consumed
  -- -------------------------------------------------------------------------

  it("a registration survives multiple resolve calls", function()
    registry.register(make_spec("Persistent", true, valid_factory))
    local p1 = registry.resolve("/path", {})
    local p2 = registry.resolve("/path", {})
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
    local a = make_spec("A", true, valid_factory)
    local b = make_spec("B", false, valid_factory)
    registry.register(a)
    registry.register(b)
    local list = registry.registered()
    assert.equals(2, #list)
    assert.equals("A", list[1].name)
    assert.equals("B", list[2].name)
  end)

  it("registered() returns a copy — mutations do not affect internal state", function()
    local a = make_spec("A", true, valid_factory)
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
    registry.register(make_spec("X", true, valid_factory))
    registry.reset()
    assert.same({}, registry.registered())
  end)

  it("resolve returns nil after reset even if a spec was registered before", function()
    registry.register(make_spec("X", true, valid_factory))
    registry.reset()
    assert.is_nil(registry.resolve("/path", {}))
  end)
end)
