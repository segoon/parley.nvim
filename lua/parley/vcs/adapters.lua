--- Local VCS command contracts. Commands are argument arrays, never shell text.
local M = {}

--- @class parley.VcsAdapter
--- @field head fun(): string[]
--- @field show fun(revision: string, path: string): string[]
--- @field status fun(path: string): string[]
--- @field dirty fun(output: string): boolean|nil, string|nil
--- @field diff fun(base: string, head: string, path: string): string[]

--- @type table<string, parley.VcsAdapter>
local adapters = {
  git = {
    head = function()
      return { "git", "rev-parse", "HEAD" }
    end,
    show = function(revision, path)
      return { "git", "show", revision .. ":" .. path }
    end,
    status = function(path)
      return { "git", "status", "--porcelain", "--", path }
    end,
    dirty = function(output)
      return output ~= ""
    end,
    diff = function(base, head, path)
      return {
        "git",
        "diff",
        "--no-ext-diff",
        "--no-color",
        "--unified=0",
        "origin/" .. base .. "..." .. head,
        "--",
        path,
      }
    end,
  },
  arc = {
    head = function()
      return { "arc", "rev-parse", "HEAD" }
    end,
    show = function(revision, path)
      return { "arc", "show", revision .. ":" .. path }
    end,
    status = function(path)
      return { "arc", "status", "--json", "--", path }
    end,
    dirty = function(output)
      local ok, data = pcall(vim.json.decode, output)
      if not ok or type(data) ~= "table" or type(data.status) ~= "table" then
        return nil, "invalid Arc status response"
      end
      for _, entries in pairs(data.status) do
        if type(entries) ~= "table" then
          return nil, "invalid Arc status entries"
        end
        if next(entries) ~= nil then
          return true
        end
      end
      return false
    end,
    diff = function(base, head, path)
      return { "arc", "diff", "--base", "--git", "--no-color", "--unified=0", base, head, "--", path }
    end,
  },
}

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
