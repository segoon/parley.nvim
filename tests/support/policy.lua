--- Filesystem inventory and dependency checks used by policy tests.
local dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
local lexer = dofile(dir .. "/lua_tokens.lua")
local M = { code = lexer.code }

--- @param root string
--- @return string[]
function M.discover(root)
  local result = {}
  for _, prefix in ipairs({ "lua", "plugin" }) do
    for _, path in ipairs(vim.fn.glob(root .. "/" .. prefix .. "/**/*.lua", false, true)) do
      result[#result + 1] = path:sub(#root + 2)
    end
  end
  table.sort(result)
  return result
end

--- @param policy table
--- @param files string[]
--- @return string[], table<string, string>
function M.inventory(policy, files)
  local errors, mapping, actual = {}, {}, {}
  for _, file in ipairs(files) do
    actual[file] = true
  end
  for layer, spec in pairs(policy.layers) do
    for _, file in ipairs(spec.modules) do
      if mapping[file] then
        errors[#errors + 1] = "duplicate assignment: " .. file
      end
      if not actual[file] then
        errors[#errors + 1] = "stale assignment: " .. file
      end
      mapping[file] = layer
    end
  end
  for _, file in ipairs(files) do
    if not mapping[file] then
      errors[#errors + 1] = "missing assignment: " .. file
    end
    if file:match("^lua/parley/providers/") then
      if mapping[file] ~= "providers" then
        errors[#errors + 1] = "provider outside provider layer: " .. file
      end
    elseif mapping[file] == "providers" then
      errors[#errors + 1] = "shared file in provider layer: " .. file
    end
  end
  table.sort(errors)
  return errors, mapping
end

--- @param source string
--- @param path string
--- @return {name: string, line: integer}[], string[]
function M.imports(source, path)
  local t = lexer.scan(source)
  local imports, errors = {}, {}
  --- @param i integer
  --- @return string|nil
  local function value(i)
    return t[i] and t[i].value
  end
  --- @param i integer
  --- @param message string
  local function fail(i, message)
    errors[#errors + 1] = string.format("%s:%d %s", path, t[i].line, message)
  end
  --- @param i integer
  --- @param arg integer
  --- @param closing boolean
  local function literal(i, arg, closing)
    if not t[arg] or t[arg].kind ~= "string" or (closing and value(arg + 1) ~= ")") then
      fail(i, "import requires a literal module name")
    elseif
      value(arg):find("[/\\]")
      or value(arg):find("..", 1, true)
      or value(arg):sub(1, 1) == "."
      or value(arg):sub(-1) == "."
    then
      fail(i, "import requires a canonical dotted module name")
    else
      imports[#imports + 1] = { name = value(arg), line = t[i].line }
    end
  end
  --- @param i integer
  --- @param token PolicyToken
  local function inspect(i, token)
    if token.kind == "name" and token.value == "require" then
      if
        path == "lua/parley/health.lua"
        and value(i - 1) == "="
        and value(i - 2) == "_require"
        and value(i - 3) == "."
        and value(i - 4) == "M"
      then
        -- The sole injectable loader alias; every use below must be literal.
        return
      elseif value(i - 1) == "." or value(i - 1) == ":" then
        fail(i, "untracked loader access")
      elseif value(i - 1) == "(" and value(i - 2) == "pcall" and value(i + 1) == "," then
        literal(i, i + 2, true)
      elseif value(i + 1) == "(" then
        literal(i, i + 2, true)
      elseif t[i + 1] and t[i + 1].kind == "string" then
        literal(i, i + 1, false)
      else
        fail(i, "untracked loader alias or use")
      end
    elseif token.kind == "name" and token.value == "_require" then
      if path ~= "lua/parley/health.lua" or value(i - 1) ~= "." or value(i - 2) ~= "M" then
        fail(i, "untracked loader alias")
      elseif value(i + 1) == "=" and value(i + 2) == "require" then
        -- Declaration checked above.
        return
      elseif value(i - 3) == "(" and value(i - 4) == "pcall" and value(i + 1) == "," then
        literal(i, i + 2, true)
      else
        fail(i, "untracked health loader use")
      end
    elseif token.kind == "string" and token.value == "require" and value(i - 1) == "[" then
      fail(i, "untracked indexed loader access")
    elseif token.kind == "name" and vim.tbl_contains({ "loadfile", "dofile", "loadstring" }, token.value) then
      fail(i, "untracked source loader")
    end
  end
  for i, token in ipairs(t) do
    inspect(i, token)
  end
  return imports, errors
end

--- @param name string
--- @param files table<string, boolean>
--- @return string|nil, boolean
function M.resolve(name, files)
  local stem = "lua/" .. name:gsub("%.", "/")
  if files[stem .. ".lua"] then
    return stem .. ".lua", true
  end
  if files[stem .. "/init.lua"] then
    return stem .. "/init.lua", true
  end
  local internal = name == "parley" or name:match("^parley%.") or name:match("^telescope%._extensions%.parley")
  return nil, not not internal
end

--- @param policy table
--- @param sources table<string, string>
--- @return string[]
function M.dependencies(policy, sources)
  local files = vim.tbl_keys(sources)
  table.sort(files)
  local errors, mapping = M.inventory(policy, files)
  local actual = {}
  for _, file in ipairs(files) do
    actual[file] = true
  end
  for _, file in ipairs(files) do
    local imports, import_errors = M.imports(sources[file], file)
    vim.list_extend(errors, import_errors)
    local layer = mapping[file]
    for _, import in ipairs(imports) do
      local dest, internal = M.resolve(import.name, actual)
      local prefix = string.format("%s:%d imports %s", file, import.line, import.name)
      if internal and not dest then
        errors[#errors + 1] = prefix .. " (missing internal module)"
      elseif dest and layer and mapping[dest] then
        if
          not file:match("^lua/parley/providers/")
          and dest:match("^lua/parley/providers/")
          and not (file == "lua/parley/init.lua" and dest == "lua/parley/providers/init.lua")
        then
          errors[#errors + 1] = prefix .. " (provider boundary)"
        elseif mapping[dest] ~= layer and not vim.tbl_contains(policy.layers[layer].depends, mapping[dest]) then
          errors[#errors + 1] = prefix .. " (undeclared layer dependency: " .. layer .. " -> " .. mapping[dest] .. ")"
        end
      end
    end
  end
  table.sort(errors)
  return errors
end
return M
