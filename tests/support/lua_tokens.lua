--- Small lexical scanner for architecture checks, not a Lua evaluator.
local M = {}

--- @class PolicyToken
--- @field kind string
--- @field value string
--- @field line integer
--- @field first integer
--- @field last integer

--- @param source string
--- @return PolicyToken[]
function M.scan(source)
  local tokens, pos, line = {}, 1, 1
  --- @param last integer
  local function advance(last)
    local _, count = source:sub(pos, last):gsub("\n", "")
    line = line + count
    pos = last + 1
  end
  --- @param start integer
  --- @return integer|nil
  local function long_end(start)
    local equals = source:sub(start):match("^%[(=*)%[")
    if not equals then
      return nil
    end
    local _, finish = source:find("]" .. equals .. "]", start + #equals + 2, true)
    assert(finish, "unterminated long string/comment at line " .. line)
    return finish
  end
  while pos <= #source do
    local ch = source:sub(pos, pos)
    if ch:match("%s") then
      advance(pos)
    elseif source:sub(pos, pos + 1) == "--" then
      local last = long_end(pos + 2) or ((source:find("\n", pos, true) or (#source + 1)) - 1)
      advance(last)
    else
      local first, token_line = pos, line
      local kind, value, last
      if ch == '"' or ch == "'" then
        last = pos + 1
        while last <= #source and source:sub(last, last) ~= ch do
          if source:sub(last, last) == "\\" then
            last = last + 1
          end
          last = last + 1
        end
        assert(last <= #source, "unterminated string at line " .. line)
        kind = "string"
      elseif ch == "[" and long_end(pos) then
        last, kind = long_end(pos), "string"
      elseif ch:match("[%a_]") then
        value = source:sub(pos):match("^[%w_]+")
        last, kind = pos + #value - 1, "name"
      else
        last, kind, value = pos, "symbol", ch
      end
      if kind == "string" then
        -- Only the lexically isolated literal is evaluated, never source code.
        local literal = source:sub(first, last)
        value = assert(loadstring("return " .. literal))()
      end
      tokens[#tokens + 1] = { kind = kind, value = value, line = token_line, first = first, last = last }
      advance(last)
    end
  end
  return tokens
end

--- Preserve code and line numbers while masking comments and string literals.
--- @param source string
--- @return string
function M.code(source)
  local tokens = M.scan(source)
  local out, pos = {}, 1
  --- @param text string
  --- @return string
  local function mask(text)
    return (text:gsub("[^\n]", " "))
  end
  for _, token in ipairs(tokens) do
    out[#out + 1] = mask(source:sub(pos, token.first - 1))
    local text = source:sub(token.first, token.last)
    out[#out + 1] = token.kind == "string" and mask(text) or text
    pos = token.last + 1
  end
  out[#out + 1] = mask(source:sub(pos))
  return table.concat(out)
end
return M
