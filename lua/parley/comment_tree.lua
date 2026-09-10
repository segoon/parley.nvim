--- Iterative thread traversal: preserve parent IDs while bounding cycles safely.
local M = {}
--- @param a parley.Comment
--- @param b parley.Comment
--- @return boolean
local function earlier(a, b)
  if a.created_at ~= b.created_at then
    return a.created_at < b.created_at
  end
  return a.id < b.id
end

--- @param comments parley.Comment[]
--- @return parley.Comment[], table<string, integer>, string|nil Ordered comments, depths, ancestry warning.
function M.order(comments)
  local by_id, children, roots, sorted = {}, {}, {}, {}
  for _, c in ipairs(comments) do
    by_id[c.id] = c
    sorted[#sorted + 1] = c
  end
  table.sort(sorted, earlier)
  local warning
  for _, c in ipairs(sorted) do
    local parent = c.parent_comment_id
    if parent and by_id[parent] then
      children[parent] = children[parent] or {}
      children[parent][#children[parent] + 1] = c
    else
      roots[#roots + 1] = c
      if parent then
        warning = "missing_parent"
      end
    end
  end
  local ordered, depths = {}, {}
  --- @param root parley.Comment
  local function visit(root)
    local stack = { { comment = root, depth = 0 } }
    while #stack > 0 do
      local node = table.remove(stack)
      local c = node.comment
      if depths[c.id] == nil then
        depths[c.id] = node.depth
        ordered[#ordered + 1] = c
        local replies = children[c.id] or {}
        for i = #replies, 1, -1 do
          stack[#stack + 1] = { comment = replies[i], depth = node.depth + 1 }
        end
      end
    end
  end
  for _, root in ipairs(roots) do
    visit(root)
  end
  for _, c in ipairs(sorted) do
    if depths[c.id] == nil then
      warning = "cycle"
      visit(c)
    end
  end
  return ordered, depths, warning
end

--- Connected components include shared missing parents, so orphan siblings stay together.
--- @param comments parley.Comment[]
--- @return parley.Comment[][]
function M.groups(comments)
  local parents = {}
  --- @param id string
  --- @return string
  local function root(id)
    parents[id] = parents[id] or id
    local r = id
    while parents[r] ~= r do
      r = parents[r]
    end
    while parents[id] ~= id do
      local next_id = parents[id]
      parents[id] = r
      id = next_id
    end
    return r
  end
  for _, c in ipairs(comments) do
    if c.parent_comment_id then
      parents[root(c.id)] = root(c.parent_comment_id)
    else
      root(c.id)
    end
  end
  local components = {}
  for _, c in ipairs(comments) do
    local id = root(c.id)
    components[id] = components[id] or {}
    components[id][#components[id] + 1] = c
  end
  local groups = {}
  for _, group in pairs(components) do
    groups[#groups + 1] = M.order(group)
  end
  table.sort(groups, function(a, b)
    return earlier(a[1], b[1])
  end)
  return groups
end
return M
