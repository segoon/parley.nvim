--- parley.runtime.fs — filesystem helpers with async and sync entrypoints.

local await = require("parley.runtime.await")

local M = {}

local uv = vim.uv or vim.loop

--- @param path string
--- @return string[]
local function path_segments(path)
  local segments = {}
  for segment in path:gmatch("[^/]+") do
    segments[#segments + 1] = segment
  end
  return segments
end

--- @param path string
--- @return string
local function normalize_path(path)
  if path == "" then
    return "."
  end
  return path
end

--- @param path string
--- @return string[]
local function mkdir_targets(path)
  local normalized = normalize_path(path)
  local absolute = normalized:sub(1, 1) == "/"
  local current = absolute and "/" or ""
  local targets = {}

  for _, segment in ipairs(path_segments(normalized)) do
    if current == "" or current == "/" then
      current = current .. segment
    else
      current = current .. "/" .. segment
    end
    targets[#targets + 1] = current
  end

  return targets
end

--- @param err string|nil
--- @param code string
--- @return boolean
local function has_error_code(err, code)
  return type(err) == "string" and err:find(code, 1, true) ~= nil
end

--- @param path string
--- @return uv.aliases.fs_stat_table|nil
local function stat_async(path)
  local err, stat = await.callback(function(callback)
    uv.fs_stat(path, callback)
  end)
  if err ~= nil then
    return nil
  end
  return stat
end

--- @param path string
--- @return string|nil
function M.read_file(path)
  local err_open, fd = await.callback(function(callback)
    uv.fs_open(path, "r", 438, callback)
  end)
  if err_open ~= nil or fd == nil then
    return nil
  end

  local stat = stat_async(path)
  if not stat then
    await.callback(function(callback)
      uv.fs_close(fd, callback)
    end)
    return nil
  end

  local err_read, data = await.callback(function(callback)
    uv.fs_read(fd, stat.size, 0, callback)
  end)
  await.callback(function(callback)
    uv.fs_close(fd, callback)
  end)
  if err_read ~= nil then
    return nil
  end
  return data
end

--- @param path string
--- @param content string
function M.write_file(path, content)
  local err_open, fd = await.callback(function(callback)
    uv.fs_open(path, "w", 420, callback)
  end)
  assert(err_open == nil and fd ~= nil, string.format("parley.runtime.fs: cannot open %s for writing", path))

  local err_write = await.callback(function(callback)
    uv.fs_write(fd, content, 0, callback)
  end)
  await.callback(function(callback)
    uv.fs_close(fd, callback)
  end)
  assert(err_write == nil, string.format("parley.runtime.fs: cannot write %s", path))
end

--- @param path string
function M.mkdir_p(path)
  for _, target in ipairs(mkdir_targets(path)) do
    local err = await.callback(function(callback)
      uv.fs_mkdir(target, 493, callback)
    end)
    if err ~= nil and not has_error_code(err, "EEXIST") then
      error(string.format("parley.runtime.fs: cannot create directory %s: %s", target, err), 0)
    end
  end
end

--- @param path string
--- @return table[]
local function scandir_async(path)
  local err, req = await.callback(function(callback)
    uv.fs_scandir(path, callback)
  end)
  if err ~= nil or req == nil then
    return {}
  end

  local entries = {}
  while true do
    local name, entry_type = uv.fs_scandir_next(req)
    if not name then
      break
    end
    entries[#entries + 1] = { name = name, type = entry_type }
  end
  return entries
end

--- @param path string
function M.rm_rf(path)
  local stat = stat_async(path)
  if not stat then
    return
  end

  if stat.type == "directory" then
    for _, entry in ipairs(scandir_async(path)) do
      M.rm_rf(path .. "/" .. entry.name)
    end
    local err = await.callback(function(callback)
      uv.fs_rmdir(path, callback)
    end)
    if err ~= nil and not has_error_code(err, "ENOENT") then
      error(string.format("parley.runtime.fs: cannot remove directory %s: %s", path, err), 0)
    end
    return
  end

  local err = await.callback(function(callback)
    uv.fs_unlink(path, callback)
  end)
  if err ~= nil and not has_error_code(err, "ENOENT") then
    error(string.format("parley.runtime.fs: cannot remove file %s: %s", path, err), 0)
  end
end

--- @param path string
--- @return string|nil
function M.read_file_sync(path)
  local fh = io.open(path, "r")
  if not fh then
    return nil
  end
  local content = fh:read("*a")
  fh:close()
  return content
end

--- @param path string
--- @param content string
function M.write_file_sync(path, content)
  local fh = assert(io.open(path, "w"))
  fh:write(content)
  fh:close()
end

--- @param path string
function M.mkdir_p_sync(path)
  vim.fn.mkdir(path, "p")
end

--- @param path string
function M.rm_rf_sync(path)
  vim.fn.delete(path, "rf")
end

return M
