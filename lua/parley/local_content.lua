--- Revision content and local text snapshots for VCS-independent anchoring.
local vcs = require("parley.vcs")
local fs = require("parley.runtime.fs")
local M = {}

--- @type table<string, string>
M._revisions = {}
--- @type fun(info: parley.VcsInfo, revision: string, path: string): string|nil, string|nil
M._read_revision = vcs.read_file

--- @param path string
--- @return string
function M.canonical(path)
  return (vim.uv or vim.loop).fs_realpath(path) or vim.fs.normalize(path)
end

--- @param path string
--- @return integer|nil
function M.buffer(path)
  path = M.canonical(path)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if
      vim.api.nvim_buf_is_loaded(bufnr)
      and vim.bo[bufnr].buftype == ""
      and M.canonical(vim.api.nvim_buf_get_name(bufnr)) == path
    then
      return bufnr
    end
  end
end

--- Normalize CRLF without stripping trailing blank lines.
--- @param text string
--- @return string
function M.normalize(text)
  return (text:gsub("\r\n", "\n"))
end

--- @param path string
--- @return string|nil, string|nil
function M.read_local(path)
  local bufnr = M.buffer(path)
  if bufnr then
    local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
    if vim.bo[bufnr].endofline then
      text = text .. "\n"
    end
    return text
  end
  local text = fs.read_file(path)
  return text, text == nil and "working-tree file is unavailable" or nil
end

--- @param info parley.VcsInfo
--- @param revision string
--- @param path string
--- @return string|nil, string|nil
function M.revision(info, revision, path)
  local key = table.concat({ info.vcs, M.canonical(info.root), revision, path }, "\0")
  if M._revisions[key] ~= nil then
    return M._revisions[key]
  end
  local text, err = M._read_revision(info, revision, path)
  if text ~= nil then
    -- Bound memory while keeping immutable file contents reusable across edits.
    if vim.tbl_count(M._revisions) >= 128 then
      M._revisions = {}
    end
    M._revisions[key] = text
  end
  return text, err
end

--- Capture loaded buffer generations before an asynchronous mapping pass.
--- @param root string
--- @return string
function M.generation(root)
  local parts = {}
  root = M.canonical(root) .. "/"
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local path = M.canonical(vim.api.nvim_buf_get_name(bufnr))
      if path:sub(1, #root) == root then
        parts[#parts + 1] = string.format(
          "%s:%d:%d:%s",
          path,
          bufnr,
          vim.api.nvim_buf_get_changedtick(bufnr),
          tostring(vim.bo[bufnr].endofline)
        )
      end
    end
  end
  table.sort(parts)
  return table.concat(parts, "\0")
end

return M
