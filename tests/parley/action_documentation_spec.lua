local commands = require("parley.commands")
local capabilities = require("parley.capabilities")
local github = require("parley.providers.github.capabilities")
local arcanum = require("parley.providers.arcanum.capabilities")

describe("action documentation contract", function()
  it("documents grouped and standalone commands in the help template", function()
    local help = table.concat(vim.fn.readfile("doc/parley.nvim.txt.in"), "\n")
    for _, command in ipairs(commands.top_level) do
      if not commands.groups[command] then
        assert.is_truthy(help:find(":Parley " .. command, 1, true), command)
      end
    end
    for group, actions in pairs(commands.groups) do
      for _, action in ipairs(actions) do
        assert.is_truthy(help:find(":Parley " .. group .. " " .. action, 1, true), group .. " " .. action)
      end
    end
  end)
  it("keeps the built-in support table synchronized with provider declarations", function()
    local help = table.concat(vim.fn.readfile("doc/parley.nvim.txt.in"), "\n")
    for _, action in ipairs(capabilities.actions) do
      local gh = github.actions[action].available and "yes" or "no"
      local arc = arcanum.actions[action].available and "yes" or "no"
      assert.is_truthy(help:match("\n  " .. action .. "%s+" .. gh .. "%s+" .. arc .. "\n"), action)
    end
  end)
end)
