--- scripts/gendoc.lua — Generate vimdoc sections from LuaCATS annotations.
---
--- Parses @class / @field / @param / @return annotations from Lua source and
--- injects formatted vimdoc into doc/parley.nvim.txt between marker lines.
---
--- Usage:
---   nvim --headless -l scripts/gendoc.lua            # update in-place
---   nvim --headless -l scripts/gendoc.lua --check     # exit 1 if stale
---
--- Markers in the help file:
---   <parley-configuration-start>
---   ... generated content ...
---   <parley-configuration-end>
---
---   <parley-api-start>
---   ... generated content ...
---   <parley-api-end>

-- ---------------------------------------------------------------------------
-- Paths (relative to repo root)
-- ---------------------------------------------------------------------------

local HELP_FILE = "doc/parley.nvim.txt"
local INIT_FILE = "lua/parley/init.lua"

-- ---------------------------------------------------------------------------
-- Argument parsing
-- ---------------------------------------------------------------------------

local check_mode = false
for _, a in ipairs(vim.v.argv) do
  if a == "--check" then
    check_mode = true
  end
end

-- ---------------------------------------------------------------------------
-- File I/O
-- ---------------------------------------------------------------------------

--- @param path string
--- @return string
local function read_file(path)
  local f = assert(io.open(path, "r"))
  local content = f:read("*a")
  f:close()
  return content
end

--- @param path string
--- @param content string
local function write_file(path, content)
  local f = assert(io.open(path, "w"))
  f:write(content)
  f:close()
end

-- ---------------------------------------------------------------------------
-- Annotation parser
-- ---------------------------------------------------------------------------

--- A parsed @class block: class name, description, and ordered fields.
--- @class gendoc.ClassBlock
--- @field name string
--- @field desc string|nil
--- @field fields { name: string, type: string, desc: string }[]

--- A parsed public function: name, description, params, returns.
--- @class gendoc.FuncBlock
--- @field name string
--- @field desc string[]
--- @field params { name: string, type: string, desc: string }[]
--- @field returns { type: string, desc: string }[]

--- Parse a @field line, handling multi-word types like `table<string, table>`.
--- Returns name, type, description or nil.
--- @param line string
--- @return string|nil, string|nil, string|nil
local function parse_field_line(line)
  -- Match: --- @field name  rest-of-line
  local body = line:match("^%-%-%-%s*@field%s+(.+)$")
  if not body then
    return nil, nil, nil
  end

  -- Field name is the first word.
  local name, rest = body:match("^(%S+)%s+(.+)$")
  if not name then
    return nil, nil, nil
  end

  -- Type may contain angle brackets (generics). Track bracket depth.
  local type_chars = {}
  local depth = 0
  local type_end = 0
  for ci = 1, #rest do
    local ch = rest:sub(ci, ci)
    if ch == "<" then
      depth = depth + 1
    elseif ch == ">" then
      depth = depth - 1
    end
    if depth == 0 and ch == " " then
      type_end = ci
      break
    end
    type_chars[#type_chars + 1] = ch
  end

  local ftype = table.concat(type_chars)
  local desc = ""
  if type_end > 0 then
    desc = vim.trim(rest:sub(type_end + 1))
  end

  return name, ftype, desc
end

--- Parse all @class blocks from source text.
--- @param source string
--- @return table<string, gendoc.ClassBlock>
local function parse_classes(source)
  local classes = {}
  local lines = vim.split(source, "\n", { plain = true })
  local i = 1
  while i <= #lines do
    local line = lines[i]
    local class_name = line:match("^%-%-%-%s*@class%s+(%S+)%s*$")
    if class_name then
      local block = { name = class_name, desc = nil, fields = {} }
      -- Look backwards for a description line.
      if i > 1 then
        local prev = lines[i - 1]
        local desc = prev:match("^%-%-%- (.+)$")
        if desc and not desc:match("^@") then
          block.desc = desc
        end
      end
      -- Scan forward for @field lines.
      local j = i + 1
      while j <= #lines do
        local fname, ftype, fdesc = parse_field_line(lines[j])
        if fname then
          block.fields[#block.fields + 1] = { name = fname, type = ftype, desc = fdesc }
          j = j + 1
        else
          break
        end
      end
      classes[class_name] = block
      i = j
    else
      i = i + 1
    end
  end
  return classes
end

--- Parse the defaults table from init.lua to extract default values.
--- Returns a flat map of dotted-key -> default value string.
--- @param source string
--- @return table<string, string>
local function parse_defaults(source)
  local result = {}
  -- Extract the defaults table block.
  local block = source:match("local defaults = (%b{})")
  if not block then
    return result
  end

  --- Walk the table string character by character, tracking brace depth.
  --- Only processes key = value assignments at depth 0 of this block.
  --- @param tbl_str string
  --- @param prefix string
  local function walk(tbl_str, prefix)
    local inner = tbl_str:sub(2, -2)
    local len = #inner
    local pos = 1

    while pos <= len do
      -- Skip whitespace and commas.
      local skip_end = inner:match("^[%s,]+()", pos)
      if skip_end then
        pos = skip_end
      end
      if pos > len then
        break
      end

      -- Try to match key = ... (key may contain underscores).
      local key, after_eq = inner:match("([%w_]+)%s*=%s*()", pos)
      -- Ensure key starts exactly at pos.
      if not key then
        pos = pos + 1
        goto continue_walk
      end
      -- Verify the match starts at pos by checking the found position.
      local key_start = inner:find("[%w_]+%s*=", pos)
      if key_start ~= pos then
        pos = pos + 1
        goto continue_walk
      end

      pos = after_eq
      local full_key = prefix ~= "" and (prefix .. "." .. key) or key

      if inner:sub(pos, pos) == "{" then
        -- Nested table: find matching close brace.
        local nested = inner:match("(%b{})", pos)
        if nested then
          walk(nested, full_key)
          pos = pos + #nested
        else
          break
        end
      else
        -- Scalar value: read to end of line.
        local val_str = inner:match("([^\n]+)", pos)
        if val_str then
          pos = pos + #val_str
          val_str = val_str:gsub("%s*%-%-.*$", ""):gsub(",%s*$", "")
          val_str = vim.trim(val_str)
          if val_str ~= "" then
            result[full_key] = val_str
          end
        else
          break
        end
      end

      ::continue_walk::
    end
  end

  walk(block, "")
  return result
end

--- Parse public function annotations from init.lua.
--- Only picks up `function M.xxx(...)` preceded by annotation blocks.
--- Skips functions starting with underscore (private).
--- @param source string
--- @return gendoc.FuncBlock[]
local function parse_functions(source)
  local funcs = {}
  local lines = vim.split(source, "\n", { plain = true })
  local i = 1
  while i <= #lines do
    local line = lines[i]
    local fname = line:match("^function M%.(%w+)%(")
    if fname and not fname:match("^_") then
      local desc_lines = {}
      local params = {}
      local returns = {}
      local j = i - 1
      while j >= 1 do
        local al = lines[j]
        if not al:match("^%-%-%-") then
          break
        end
        -- @param can have multi-word types: "parley.Config | nil  Description"
        -- Split on two-or-more consecutive spaces to separate type from desc.
        local pname, prest = al:match("^%-%-%-%s*@param%s+(%S+)%s+(.+)$")
        if pname then
          local ptype, pdesc = prest:match("^(.-)%s%s+(.+)$")
          if not ptype or ptype == "" then
            ptype = prest
            pdesc = ""
          end
          ptype = vim.trim(ptype)
          table.insert(params, 1, { name = pname, type = ptype, desc = vim.trim(pdesc) })
          j = j - 1
          goto continue_backward
        end
        local rtype, rdesc = al:match("^%-%-%-%s*@return%s+(%S+)%s*(.*)")
        if rtype then
          table.insert(returns, 1, { type = rtype, desc = vim.trim(rdesc) })
          j = j - 1
          goto continue_backward
        end
        if al:match("^%-%-%-%s*@type") then
          j = j - 1
          goto continue_backward
        end
        local text = al:match("^%-%-%- ?(.*)$")
        if text then
          table.insert(desc_lines, 1, text)
        end
        j = j - 1
        ::continue_backward::
      end

      local sig = line:match("^function M%.(" .. fname .. "%b())")
      funcs[#funcs + 1] = {
        name = sig or fname,
        desc = desc_lines,
        params = params,
        returns = returns,
      }
    end
    i = i + 1
  end
  return funcs
end

-- ---------------------------------------------------------------------------
-- Vimdoc formatters
-- ---------------------------------------------------------------------------

local WIDTH = 78

--- Right-pad `s` with spaces to `width`.
--- @param s string
--- @param width integer
--- @return string
local function rpad(s, width)
  if #s >= width then
    return s
  end
  return s .. string.rep(" ", width - #s)
end

--- Format a leaf config field as a vimdoc line.
--- @param field { name: string, type: string, desc: string }
--- @param default_val string|nil
--- @return string[]
local function fmt_config_leaf(field, default_val)
  local out = {}
  local type_str = "(`" .. field.type .. "`)"
  local def_str = default_val and ("  Default: `" .. default_val .. "`") or ""
  out[#out + 1] = "    " .. field.name .. "  " .. type_str .. def_str
  if field.desc and field.desc ~= "" then
    out[#out + 1] = "        " .. field.desc
  end
  out[#out + 1] = ""
  return out
end

--- Format a configuration class block as vimdoc.
--- At the top level (prefix == ""), leaf fields are emitted first, then
--- sub-class groups, so that simple options don't appear to belong to a
--- preceding sub-class section.
--- @param class gendoc.ClassBlock
--- @param defaults table<string, string>
--- @param prefix string
--- @param classes table<string, gendoc.ClassBlock>
--- @return string[]
local function fmt_config_class(class, defaults, prefix, classes)
  local out = {}

  -- Separate leaf fields from sub-class fields.
  local leaves = {}
  local groups = {}
  for _, field in ipairs(class.fields) do
    local sub_class = classes[field.type]
    if sub_class and #sub_class.fields > 0 then
      groups[#groups + 1] = field
    else
      leaves[#leaves + 1] = field
    end
  end

  -- Emit leaf fields first.
  for _, field in ipairs(leaves) do
    local full_key = prefix ~= "" and (prefix .. "." .. field.name) or field.name
    vim.list_extend(out, fmt_config_leaf(field, defaults[full_key]))
  end

  -- Emit sub-class groups.
  for _, field in ipairs(groups) do
    local full_key = prefix ~= "" and (prefix .. "." .. field.name) or field.name
    local sub_class = classes[field.type]
    out[#out + 1] = ""
    local tag_name = "parley-config-" .. field.name
    local starred = "*" .. tag_name .. "*"
    out[#out + 1] = rpad(field.name .. " ~", WIDTH - #starred - 1) .. starred
    if field.desc and field.desc ~= "" then
      out[#out + 1] = ""
      out[#out + 1] = "    " .. field.desc
    end
    out[#out + 1] = ""
    -- Recurse — inner groups keep original order (no reordering needed).
    local sub_lines = fmt_config_class(sub_class, defaults, full_key, classes)
    vim.list_extend(out, sub_lines)
  end

  return out
end

--- Format public functions as vimdoc.
--- @param funcs gendoc.FuncBlock[]
--- @return string[]
local function fmt_functions(funcs)
  local out = {}

  for fi, fn in ipairs(funcs) do
    local qualified = "parley." .. fn.name
    local tag = "parley." .. fn.name
    local starred = "*" .. tag .. "*"
    out[#out + 1] = rpad(qualified, WIDTH - #starred - 1) .. starred

    -- Description.
    local in_code = false
    for _, line in ipairs(fn.desc) do
      if line:match("^```") then
        if not in_code then
          out[#out + 1] = " >lua"
          in_code = true
        else
          out[#out + 1] = "<"
          in_code = false
        end
      elseif in_code then
        out[#out + 1] = "    " .. line
      elseif line == "" then
        out[#out + 1] = ""
      else
        out[#out + 1] = "    " .. line
      end
    end
    if in_code then
      out[#out + 1] = "<"
    end

    -- Parameters.
    if #fn.params > 0 then
      out[#out + 1] = ""
      out[#out + 1] = "    Parameters: ~"
      for _, p in ipairs(fn.params) do
        local entry = "      - {" .. p.name .. "}  (`" .. p.type .. "`)"
        if p.desc ~= "" then
          entry = entry .. "  " .. p.desc
        end
        out[#out + 1] = entry
      end
    end

    -- Return.
    if #fn.returns > 0 then
      out[#out + 1] = ""
      out[#out + 1] = "    Return: ~"
      for _, r in ipairs(fn.returns) do
        local entry = "      (`" .. r.type .. "`)"
        if r.desc ~= "" then
          entry = entry .. "  " .. r.desc
        end
        out[#out + 1] = entry
      end
    end

    if fi < #funcs then
      out[#out + 1] = ""
    end
  end

  return out
end

-- ---------------------------------------------------------------------------
-- Marker replacement
-- ---------------------------------------------------------------------------

--- Replace content between markers in the help file text.
--- Uses line-by-line processing to avoid Lua pattern issues with special
--- characters (%, etc.) in the replacement content.
--- @param text string
--- @param start_marker string
--- @param end_marker string
--- @param replacement string[]
--- @return string
local function replace_region(text, start_marker, end_marker, replacement)
  local lines = vim.split(text, "\n", { plain = true })
  local out = {}
  local state = "before" -- "before" | "inside" | "after"
  local found = false

  for _, line in ipairs(lines) do
    if state == "before" then
      out[#out + 1] = line
      if line:find(start_marker, 1, true) then
        state = "inside"
        found = true
        -- Insert replacement lines.
        for _, rline in ipairs(replacement) do
          out[#out + 1] = rline
        end
      end
    elseif state == "inside" then
      if line:find(end_marker, 1, true) then
        out[#out + 1] = line
        state = "after"
      end
      -- Skip old content between markers.
    else
      out[#out + 1] = line
    end
  end

  if not found then
    io.stderr:write("ERROR: marker not found: " .. start_marker .. "\n")
    os.exit(1)
  end

  return table.concat(out, "\n")
end

-- ---------------------------------------------------------------------------
-- Main
-- ---------------------------------------------------------------------------

local function main()
  local init_source = read_file(INIT_FILE)
  local help_text = read_file(HELP_FILE)

  -- Parse annotations and defaults.
  local classes = parse_classes(init_source)
  local defaults = parse_defaults(init_source)
  local funcs = parse_functions(init_source)

  -- Generate configuration section.
  local config_class = classes["parley.Config"]
  local config_lines = {}
  if config_class then
    config_lines = fmt_config_class(config_class, defaults, "", classes)
  end
  -- Prepend the full defaults example.
  local config_preamble = {
    "",
    "The full default configuration:",
    " >lua",
  }
  -- Extract the defaults block from source for the example.
  local defaults_block = init_source:match("(local defaults = %b{})")
  if defaults_block then
    local example = defaults_block:gsub("^local defaults = ", "require('parley').setup(")
    example = example .. ")"
    for _, line in ipairs(vim.split(example, "\n", { plain = true })) do
      config_preamble[#config_preamble + 1] = "    " .. line
    end
  end
  config_preamble[#config_preamble + 1] = "<"
  config_preamble[#config_preamble + 1] = ""
  config_preamble[#config_preamble + 1] = "Options: ~"

  local full_config = {}
  vim.list_extend(full_config, config_preamble)
  vim.list_extend(full_config, config_lines)

  -- Generate API section.
  local api_lines = fmt_functions(funcs)

  -- Replace marker regions.
  local result = help_text
  result = replace_region(result, "<parley-configuration-start>", "<parley-configuration-end>", full_config)
  result = replace_region(result, "<parley-api-start>", "<parley-api-end>", api_lines)

  if check_mode then
    if result == help_text then
      print("doc/parley.nvim.txt is up to date")
      os.exit(0)
    else
      io.stderr:write("ERROR: doc/parley.nvim.txt is stale. Run: make doc\n")
      os.exit(1)
    end
  else
    write_file(HELP_FILE, result)
    print("Updated " .. HELP_FILE)
  end
end

main()
vim.cmd("qa!")
