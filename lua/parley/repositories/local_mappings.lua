--- Checkout-specific projections of shared remote discussions.
local anchor = require("parley.anchor")
local content = require("parley.local_content")
local M = {}
--- @type table<string, table>
M._entries = {}
--- @type table<string, string>
M._warnings = {}
--- @type table<string, integer>
M._epochs = {}

--- @param info parley.VcsInfo
--- @return string
function M.key(info)
  return info.vcs .. "\0" .. content.canonical(info.root)
end

--- Invalidate local projections without touching remote review data.
--- @param info parley.VcsInfo
function M.invalidate(info)
  local key = M.key(info)
  M._epochs[key] = (M._epochs[key] or 0) + 1
  M._entries[key] = nil
end

--- @param ctx table
--- @param shared table
--- @return table|nil  nil means buffer content changed while awaiting I/O
function M.get(ctx, shared)
  local info = ctx.vcs_info
  local key = M.key(info)
  local generation = content.generation(info.root)
  local epoch = M._epochs[key]
  local entry = M._entries[key]
  if entry and entry.shared == shared and entry.generation == generation then
    return entry.mappings
  end
  local mappings = anchor.map_discussions(info, shared.head_sha or "", shared.all_discussions or {})
  if generation ~= content.generation(info.root) or epoch ~= M._epochs[key] then
    return nil
  end
  for _, disc in ipairs(shared.all_discussions or {}) do
    local mapping = mappings[disc.id]
    local buf = mapping and content.buffer(info.root .. "/" .. disc.file)
    if buf and mapping.local_line then
      local count = vim.api.nvim_buf_line_count(buf)
      local line = math.max(1, math.min(mapping.local_line, count))
      if line ~= mapping.local_line then
        mapping.stale, mapping.confidence = true, 0
      end
      mapping.local_line = line
      if mapping.local_end_line then
        mapping.local_end_line = math.max(line, math.min(mapping.local_end_line, count))
      end
    end
  end
  M._entries[key] = { shared = shared, generation = generation, mappings = mappings }
  local failures = {}
  for _, disc in ipairs(shared.all_discussions or {}) do
    local mapping = mappings[disc.id]
    local warning_key = key .. "\0" .. (shared.head_sha or "") .. "\0" .. (disc.file or "")
    if mapping and mapping.error then
      failures[warning_key] = true
      if M._warnings[warning_key] ~= mapping.error then
        M._warnings[warning_key] = mapping.error
        local message = "Parley: approximate discussion locations for " .. disc.file .. ": " .. mapping.error
        vim.schedule(function()
          vim.notify(message, vim.log.levels.WARN)
        end)
      end
    elseif not failures[warning_key] then
      M._warnings[warning_key] = nil
    end
  end
  return mappings
end

return M
