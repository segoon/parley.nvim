local repo_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")
local policy_path = repo_root .. "/policy.json"

---@param file_path string
---@return table
local function read_policy_json(file_path)
  local lines = vim.fn.readfile(file_path)
  return assert(vim.json.decode(table.concat(lines, "\n")))
end

---@param file_path string
---@return string
local function read_lua_strip_comments(file_path)
  local out = {}
  for _, line in ipairs(vim.fn.readfile(file_path)) do
    out[#out + 1] = line:gsub("%-%-.*$", "")
  end
  return table.concat(out, "\n")
end

---@param paths string[]
---@return string[]
local function sort_paths(paths)
  table.sort(paths)
  return paths
end

---@param policy table
---@return string[]
local function source_files(policy)
  local files = vim.deepcopy(assert(policy.source_files, "missing policy.source_files"))
  return sort_paths(files)
end

---@param policy table
---@return table<string, string>
local function module_to_layer(policy)
  local mapping = {}
  for layer_name, layer in pairs(policy.layers) do
    for _, module_path in ipairs(layer.modules) do
      assert(mapping[module_path] == nil, string.format("module assigned twice: %s", module_path))
      mapping[module_path] = layer_name
    end
  end
  return mapping
end

---@param policy table
---@return table<string, table>
local function capability_functions(policy)
  local mapping = {}
  for name, capability in pairs(policy.capabilities) do
    mapping[name] = capability.functions or {}
  end
  return mapping
end

---@param pattern string
---@return string
local function escape_lua_pattern(pattern)
  local lua_magic_chars = "([%^%$%(%)%%%.%[%]%*%+%-%?])"
  return pattern:gsub(lua_magic_chars, "%%%1")
end

---@param function_pattern string
---@return string
local function function_pattern_to_lua(function_pattern)
  local placeholder = "\0"
  local escaped = function_pattern:gsub("%%", placeholder)
  escaped = escape_lua_pattern(escaped)
  escaped = escaped:gsub(placeholder, "[^%%.:]+")
  return "^" .. escaped .. "$"
end

---@param line string
---@return table<string, true>
local function line_targets(line)
  local targets = {}

  for token in line:gmatch("[%a_][%w_]*[%.:][%a_][%w_%.:]*") do
    targets[token] = true
  end

  for token in line:gmatch("([%a_][%w_%.]*)%s*%(") do
    targets[token] = true
  end

  for token in line:gmatch("([%a_][%w_%.]*)%[") do
    targets[token] = true
  end

  -- Match chained calls like vim.system(...):wait() so returned-handle methods
  -- can be declared in the policy as callee:method capabilities.
  for callee, method in line:gmatch("([%a_][%w_%.:]*)%b()%s*:%s*([%a_][%w_]*)%s*%(") do
    targets[callee .. ":" .. method] = true
  end

  return targets
end

---@param function_pattern string
---@param target string
---@return boolean
local function function_matches(function_pattern, target)
  return target:match(function_pattern_to_lua(function_pattern)) ~= nil
end

---@param functions string[]
---@param target string
---@return string[]
local function matching_functions(functions, target)
  local matches = {}
  for _, function_pattern in ipairs(functions) do
    if function_matches(function_pattern, target) then
      matches[#matches + 1] = function_pattern
    end
  end
  return matches
end

---@param policy table
---@return string[]
local function known_functions(policy)
  local all = {}
  for _, capability in pairs(policy.capabilities) do
    for _, function_name in ipairs(capability.functions or {}) do
      all[#all + 1] = function_name
    end
  end
  table.sort(all)
  return all
end

---@param file_path string
---@param policy table
---@return string[]
local function external_api_violations(file_path, policy)
  local layer_name = module_to_layer(policy)[file_path]
  local layer = assert(policy.layers[layer_name], file_path)
  local capability_map = capability_functions(policy)
  local known = known_functions(policy)
  local allowed_functions = {}
  for _, capability_name in ipairs(layer.capabilities) do
    for _, function_name in ipairs(capability_map[capability_name] or {}) do
      allowed_functions[#allowed_functions + 1] = function_name
    end
  end

  local violations = {}
  local stripped = read_lua_strip_comments(repo_root .. "/" .. file_path)
  for line_nr, line in ipairs(vim.split(stripped, "\n", { plain = true })) do
    for target in pairs(line_targets(line)) do
      local allowed = matching_functions(allowed_functions, target)
      local all = matching_functions(known, target)
      if #all > 0 and #allowed == 0 then
        violations[#violations + 1] = string.format("%s:%d uses %s", file_path, line_nr, target)
      end
    end
  end
  table.sort(violations)
  return violations
end

---@param file_path string
---@return string[]
local function internal_requires(file_path)
  local stripped = read_lua_strip_comments(repo_root .. "/" .. file_path)
  local deps = {}
  for _, line in ipairs(vim.split(stripped, "\n", { plain = true })) do
    for module_name in line:gmatch("require%([\"'](parley%.[^\"']+)[\"']%)") do
      local path = "lua/" .. module_name:gsub("%.", "/")
      deps[#deps + 1] = vim.fn.filereadable(repo_root .. "/" .. path .. ".lua") == 1 and (path .. ".lua")
        or (path .. "/init.lua")
    end
  end
  table.sort(deps)
  return deps
end

---@param policy table
---@return string[]
local function dependency_violations(policy)
  local mapping = module_to_layer(policy)
  local violations = {}
  for _, file_path in ipairs(source_files(policy)) do
    local source_layer = assert(mapping[file_path], "missing layer for " .. file_path)
    local allowed_layers = {}
    for _, layer_name in ipairs(policy.layers[source_layer].depends) do
      allowed_layers[layer_name] = true
    end
    allowed_layers[source_layer] = true

    for _, dep_path in ipairs(internal_requires(file_path)) do
      local dep_layer = mapping[dep_path]
      if dep_layer and not allowed_layers[dep_layer] then
        violations[#violations + 1] =
          string.format("%s (%s) depends on %s (%s)", file_path, source_layer, dep_path, dep_layer)
      end
    end
  end
  table.sort(violations)
  return violations
end

---@param policy table
---@return string[]
local function cycle_violations(policy)
  local visiting = {}
  local visited = {}
  local path = {}
  local cycles = {}

  local function visit(layer_name)
    if visited[layer_name] then
      return
    end
    if visiting[layer_name] then
      local cycle = {}
      local seen = false
      for _, entry in ipairs(path) do
        if entry == layer_name then
          seen = true
        end
        if seen then
          cycle[#cycle + 1] = entry
        end
      end
      cycle[#cycle + 1] = layer_name
      cycles[#cycles + 1] = table.concat(cycle, " -> ")
      return
    end
    visiting[layer_name] = true
    path[#path + 1] = layer_name
    for _, dep in ipairs(policy.layers[layer_name].depends) do
      visit(dep)
    end
    path[#path] = nil
    visiting[layer_name] = nil
    visited[layer_name] = true
  end

  for layer_name in pairs(policy.layers) do
    visit(layer_name)
  end

  table.sort(cycles)
  return cycles
end

describe("architecture policy", function()
  it("keeps statusline independent of concrete providers", function()
    for _, dep in ipairs(internal_requires("lua/parley/statusline.lua")) do
      assert.is_nil(dep:match("^lua/parley/providers/"), "statusline imports " .. dep)
    end
  end)

  it("limits shared setup to the provider catalog", function()
    for _, dep in ipairs(internal_requires("lua/parley/init.lua")) do
      if dep:match("^lua/parley/providers/") then
        assert.equals("lua/parley/providers/init.lua", dep)
      end
    end
  end)

  it("keeps shared VCS code independent of concrete providers", function()
    local paths = { "lua/parley/vcs.lua", "lua/parley/anchor.lua", "lua/parley/local_content.lua" }
    vim.list_extend(paths, vim.fn.glob("lua/parley/vcs/**/*.lua", false, true))
    for _, path in ipairs(paths) do
      for _, dep in ipairs(internal_requires(path)) do
        assert.is_nil(dep:match("^lua/parley/providers/"), path .. " imports " .. dep)
      end
    end
  end)

  it("keeps shared health independent of concrete provider imports", function()
    for _, dep in ipairs(internal_requires("lua/parley/health.lua")) do
      assert.is_nil(dep:match("^lua/parley/providers/"), "health imports " .. dep)
    end
  end)

  it("keeps shared reaction code independent of provider implementations", function()
    for _, path in ipairs({
      "lua/parley/reactions.lua",
      "lua/parley/discussion_window/render.lua",
      "lua/parley/services/write.lua",
    }) do
      for _, dep in ipairs(internal_requires(path)) do
        assert.is_nil(dep:match("^lua/parley/providers/"), path .. " imports " .. dep)
      end
    end
  end)

  it("assigns every Lua module to exactly one layer", function()
    local policy = read_policy_json(policy_path)
    local mapping = module_to_layer(policy)
    for _, file_path in ipairs(source_files(policy)) do
      assert.is_not_nil(mapping[file_path], "missing layer for " .. file_path)
    end
    assert.same(sort_paths(source_files(policy)), sort_paths(vim.tbl_keys(mapping)))
  end)

  it("references only defined capabilities and layers", function()
    local policy = read_policy_json(policy_path)
    for layer_name, layer in pairs(policy.layers) do
      for _, capability_name in ipairs(layer.capabilities) do
        assert.is_not_nil(
          policy.capabilities[capability_name],
          string.format("unknown capability %s in %s", capability_name, layer_name)
        )
      end
      for _, dep in ipairs(layer.depends) do
        assert.is_not_nil(policy.layers[dep], string.format("unknown dependency %s in %s", dep, layer_name))
      end
    end
  end)

  it("keeps the layer graph acyclic", function()
    local policy = read_policy_json(policy_path)
    assert.same({}, cycle_violations(policy))
  end)

  it("restricts direct external API usage to declared capabilities", function()
    local policy = read_policy_json(policy_path)
    local violations = {}
    for _, file_path in ipairs(source_files(policy)) do
      vim.list_extend(violations, external_api_violations(file_path, policy))
    end
    assert.same({}, violations)
  end)

  it("restricts internal requires to declared layer dependencies", function()
    local policy = read_policy_json(policy_path)
    assert.same({}, dependency_violations(policy))
  end)
end)
