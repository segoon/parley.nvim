--- Generic registry for injected VCS command contracts.
local M = {}

--- @class parley.VcsAdapter
--- @field head fun(): string[]
--- @field show fun(revision: string, path: string): string[]
--- @field status fun(path: string): string[]
--- @field dirty fun(output: string): boolean|nil, string|nil
--- @field diff fun(base: string, head: string, path: string): string[]
--- @field diffview_range? fun(base: string, head: string): string[]|nil
---   Optional: args for diffview-plus.nvim's :DiffviewOpen scoped to this
---   VCS's base...head range; nil (or absent) if this VCS has no diffview
---   equivalent.

--- @type table<string, parley.VcsAdapter>
local adapters = {}

--- Methods every adapter must implement.
local REQUIRED_METHODS = { "head", "show", "status", "dirty", "diff" }
--- Methods an adapter may implement; passed through as-is when present.
local OPTIONAL_METHODS = { "diffview_range" }

--- @param name string
--- @param adapter parley.VcsAdapter
function M.register(name, adapter)
  assert(type(name) == "string" and name ~= "", "VCS adapter name must be a non-empty string")
  assert(type(adapter) == "table", "VCS adapter must be a table")
  assert(adapters[name] == nil, "VCS adapter already registered: " .. name)
  local validated = {}
  for _, method in ipairs(REQUIRED_METHODS) do
    assert(type(adapter[method]) == "function", "VCS adapter requires method: " .. method)
    validated[method] = adapter[method]
  end
  for _, method in ipairs(OPTIONAL_METHODS) do
    if adapter[method] ~= nil then
      assert(type(adapter[method]) == "function", "VCS adapter method must be a function: " .. method)
      validated[method] = adapter[method]
    end
  end
  adapters[name] = validated
end

--- Remove all registrations; built-ins are registered explicitly during setup.
function M.reset()
  adapters = {}
end

--- @param info parley.VcsInfo
--- @return parley.VcsAdapter|nil, string|nil
function M.get(info)
  if type(info) ~= "table" or type(info.root) ~= "string" or info.root == "" then
    return nil, "repository context is unavailable"
  end
  local adapter = adapters[info.vcs]
  if not adapter then
    return nil, "unsupported VCS: " .. tostring(info.vcs)
  end
  return adapter
end

return M
