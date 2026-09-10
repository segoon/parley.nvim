--- Git command construction and status interpretation.
--- @type parley.VcsAdapter
local adapter = {
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
}

return adapter
