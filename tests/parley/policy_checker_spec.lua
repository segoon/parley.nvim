local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")
local checker = dofile(root .. "/tests/support/policy.lua")

describe("architecture checker", function()
  it("requires a complete and unique inventory", function()
    local policy = { layers = { core = { modules = { "lua/a.lua", "lua/stale.lua", "lua/a.lua" }, depends = {} } } }
    local errors = checker.inventory(policy, { "lua/a.lua", "lua/new.lua" })
    assert.equals(3, #errors)
  end)
  it("recognizes literal imports without parsing comments or string contents as code", function()
    local imports, errors = checker.imports(
      [=[
      -- require("parley.fake")
      local text = 'require("parley.fake")'
      --[==[ require("parley.fake") ]==]
      require (
        "parley.real"
      )
      require 'parley.other'
      pcall(require, "parley")
    ]=],
      "lua/example.lua"
    )
    assert.same({}, errors)
    assert.equals(3, #imports)
    assert.equals("parley.real", imports[1].name)
    assert.equals(4, imports[1].line)
  end)
  it("rejects computed imports and loader aliases", function()
    for _, source in ipairs({
      "require(name)",
      'require("parley." .. name)',
      "local loader = require",
      "pcall(require, name)",
      '_G.require("parley.hidden")',
      '_G["require"]("parley.hidden")',
      "local loader = M._require",
      'dofile("hidden.lua")',
      'loadfile("hidden.lua")',
      "loadstring(source)",
      'require("parley/providers/acme")',
      'require("parley..providers.acme")',
    }) do
      local _, errors = checker.imports(source, "lua/example.lua")
      assert.is_true(#errors > 0, source)
    end
  end)
  it("discovers nested production files and excludes tests and scripts", function()
    local dir = vim.fn.tempname()
    for _, folder in ipairs({ "lua/nested", "plugin", "tests", "scripts" }) do
      vim.fn.mkdir(dir .. "/" .. folder, "p")
      vim.fn.writefile({ "return {}" }, dir .. "/" .. folder .. "/example.lua")
    end
    local discovered = checker.discover(dir)
    vim.fn.delete(dir, "rf")
    assert.same({ "lua/nested/example.lua", "plugin/example.lua" }, discovered)
  end)

  it("resolves root, directory, and local extension modules", function()
    local files = {
      ["lua/parley/init.lua"] = true,
      ["lua/parley/nested/init.lua"] = true,
      ["lua/telescope/_extensions/parley_example.lua"] = true,
    }
    for _, name in ipairs({ "parley", "parley.nested", "telescope._extensions.parley_example" }) do
      local path, internal = checker.resolve(name, files)
      assert.is_true(internal)
      assert.is_not_nil(path)
    end
    local path, internal = checker.resolve("parley.missing", files)
    assert.is_nil(path)
    assert.is_true(internal)
    local _, external = checker.resolve("plenary.async", files)
    assert.is_false(external)
  end)

  it("tracks the health loader without allowing dynamic forwarding", function()
    local imports, errors =
      checker.imports('M._require = require; pcall(M._require, "parley.missing")', "lua/parley/health.lua")
    assert.same({}, errors)
    assert.equals("parley.missing", imports[1].name)
    for _, source in ipairs({ "pcall(M._require, name)", "local loader = M._require", "M._require(name)" }) do
      local _, invalid = checker.imports(source, "lua/parley/health.lua")
      assert.is_true(#invalid > 0)
    end
    local _, invalid = checker.imports("M._require = require", "lua/parley/other.lua")
    assert.is_true(#invalid > 0)
  end)

  it("masks comments and strings without hiding subsequent code or changing lines", function()
    local source = 'local text = "-- vim.system()"; vim.notify("message") -- vim.wait()\nlocal long = [=[vim.cmd()]=]'
    local code = checker.code(source)
    assert.is_nil(code:find("vim.system", 1, true))
    assert.is_nil(code:find("vim.wait", 1, true))
    assert.is_nil(code:find("vim.cmd", 1, true))
    assert.is_truthy(code:find("vim.notify", 1, true))
    assert.equals(#source, #code)
  end)

  it("handles escaped literals and long-string imports", function()
    local imports, errors =
      checker.imports([=[require("parley\046core"); require [==[parley.core]==]]=], "lua/example.lua")
    assert.same({}, errors)
    assert.equals(2, #imports)
    assert.equals("parley.core", imports[1].name)
    assert.equals("parley.core", imports[2].name)
  end)
end)

describe("architecture dependency boundaries", function()
  local sources, policy
  before_each(function()
    sources = {
      ["lua/parley/init.lua"] = "",
      ["lua/parley/shared.lua"] = "",
      ["lua/parley/providers/init.lua"] = "",
      ["lua/parley/providers/acme.lua"] = "",
      ["lua/parley/core.lua"] = "",
    }
    policy = {
      layers = {
        app = { modules = { "lua/parley/init.lua", "lua/parley/shared.lua" }, depends = { "core", "providers" } },
        providers = {
          modules = { "lua/parley/providers/init.lua", "lua/parley/providers/acme.lua" },
          depends = { "core" },
        },
        core = { modules = { "lua/parley/core.lua" }, depends = {} },
      },
    }
  end)

  it("permits only the setup-to-catalog edge across the provider boundary", function()
    sources["lua/parley/init.lua"] = 'require("parley.providers")'
    sources["lua/parley/providers/init.lua"] = 'require("parley.providers.acme")'
    sources["lua/parley/providers/acme.lua"] = 'require("parley.core")'
    assert.same({}, checker.dependencies(policy, sources))
    sources["lua/parley/shared.lua"] = 'pcall(require, "parley.providers")'
    local errors = checker.dependencies(policy, sources)
    assert.equals(1, #errors)
    assert.is_truthy(errors[1]:find("lua/parley/shared.lua:1", 1, true))
    assert.is_truthy(errors[1]:find("provider boundary", 1, true))
    sources["lua/parley/shared.lua"] = ""
    sources["lua/parley/init.lua"] = 'require("parley.providers.acme")'
    assert.equals(1, #checker.dependencies(policy, sources))
  end)

  it("rejects missing internal imports and undeclared outbound layers", function()
    sources["lua/parley/shared.lua"] = 'require("parley.missing")'
    sources["lua/parley/providers/acme.lua"] = 'require("parley")'
    local errors = checker.dependencies(policy, sources)
    assert.equals(2, #errors)
    assert.is_truthy(table.concat(errors):find("missing internal module", 1, true))
    assert.is_truthy(table.concat(errors):find("undeclared layer dependency", 1, true))
  end)

  it("does not silently skip unassigned dependency targets", function()
    sources["lua/parley/unassigned.lua"] = ""
    sources["lua/parley/shared.lua"] = 'require("parley.unassigned")'
    local errors = checker.dependencies(policy, sources)
    assert.equals(1, #errors)
    assert.is_truthy(errors[1]:find("missing assignment", 1, true))
  end)

  it("enforces provider membership independently of layer permissions", function()
    policy.layers.providers.modules = { "lua/parley/providers/init.lua", "lua/parley/shared.lua" }
    policy.layers.app.modules = { "lua/parley/init.lua", "lua/parley/providers/acme.lua" }
    assert.equals(2, #checker.dependencies(policy, sources))
  end)
end)
