--- Arc command construction and status interpretation.
--- @type parley.VcsAdapter
local adapter = {
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
}

return adapter
