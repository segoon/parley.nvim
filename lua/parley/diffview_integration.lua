--- parley.diffview_integration — PR discussions inside diffview-plus.nvim.
---
--- diffview-plus.nvim opens read-only "diff buffers" showing the exact
--- content of a single revision. Comments are never local-edit-remapped
--- there (unlike regular buffers, see anchor.lua): a diffview diff buffer
--- showing the review's head revision maps PR-diff-space lines onto itself
--- with identity, so this module aliases such buffers onto the review
--- already active for a regular buffer in the same repository, reusing the
--- existing read/hover/write pipelines unmodified.
---
--- Only the "new" (head) side is supported: parley's own anchor semantics
--- (discussion.projectable / providers/*/anchors.lua) never populate
--- `side == "old"` anchors, so there is nothing to render on the base side.
---
--- No dependency on diffview being configured with parley-aware `hooks`:
--- this module listens on diffview's documented `User` autocmds, which fire
--- unconditionally, so the integration is zero-config for users who have
--- both plugins installed.

local async = require("plenary.async")
local context_repository = require("parley.repositories.context")
local provider_repository = require("parley.repositories.provider")
local review_repository = require("parley.repositories.review")
local read_service = require("parley.services.read")

local M = {}

--- @type fun(): parley.Config
M._get_config = function()
  return require("parley").config
end

-- ---------------------------------------------------------------------------
-- diffview identity resolution
-- ---------------------------------------------------------------------------

--- diffview.lib seam; replace in tests to avoid requiring a real diffview
--- install. Returns nil when diffview-plus.nvim isn't installed.
--- @type fun(): table|nil
M._get_lib = function()
  local ok, lib = pcall(require, "diffview.lib")
  if not ok then
    return nil
  end
  return lib
end

--- Find the vcs.File in the current diffview view whose buffer is `bufnr`.
--- @param bufnr integer
--- @return table|nil vcs.File
function M._resolve_file(bufnr)
  local lib = M._get_lib()
  if not lib then
    return nil
  end
  local ok, view = pcall(lib.get_current_view)
  if not ok or not view or not view.cur_entry or not view.cur_entry.layout then
    return nil
  end
  local ok2, files = pcall(function()
    return view.cur_entry.layout:files()
  end)
  if not ok2 or not files then
    return nil
  end
  for _, file in ipairs(files) do
    if file.bufnr == bufnr then
      return file
    end
  end
  return nil
end

--- Derive the VCS root from a vcs.File's absolute/relative path pair.
--- @param file table vcs.File
--- @return string|nil
function M._derive_root(file)
  if type(file.absolute_path) ~= "string" or type(file.path) ~= "string" then
    return nil
  end
  local suffix = "/" .. file.path
  if file.absolute_path:sub(-#suffix) == suffix then
    return file.absolute_path:sub(1, #file.absolute_path - #suffix)
  end
  return nil
end

--- True iff `file.rev` represents the review's head revision (or the local
--- working tree, which is equivalent for a still-open PR).
--- @param file table vcs.File
--- @param head_sha string
--- @return boolean
function M._is_head_side(file, head_sha)
  local rev = file.rev
  if not rev then
    return false
  end
  if rev.type == "LOCAL" then
    return true
  end
  local ok, rev_lib = pcall(require, "diffview.vcs.rev")
  if ok and rev_lib.RevType and rev.type == rev_lib.RevType.LOCAL then
    return true
  end
  return type(head_sha) == "string" and head_sha ~= "" and rev.commit == head_sha
end

--- Find a loaded, already-classified regular buffer in the same VCS root
--- that has an active review attached, to alias the diffview buffer onto.
--- Pure lookup over already-cached repository state; no I/O.
--- @param root string|nil
--- @return integer|nil host_bufnr
--- @return string|nil review_key
--- @return table|nil host_ctx
function M._find_host(root)
  if not root then
    return nil
  end
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local ctx = context_repository.get(bufnr)
      if ctx and ctx.kind == "regular" and ctx.vcs_info and ctx.vcs_info.root == root then
        local key = review_repository.key_for_bufnr(bufnr)
        if key then
          return bufnr, key, ctx
        end
      end
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Attach / render
-- ---------------------------------------------------------------------------

--- @type table<integer, boolean> Diffview buffers currently aliased onto a review.
M._attached = {}

--- @param bufnr integer
--- @param keymap string
local function set_new_comment_keymap(bufnr, keymap)
  if not keymap or keymap == "" then
    return
  end
  vim.keymap.set("n", keymap, function()
    require("parley.services.write").open_new_comment_input(bufnr, {})
  end, { buffer = bufnr, desc = "Parley: new comment (diffview)" })
end

--- Handle a diffview diff buffer becoming current: resolve its identity,
--- alias it onto the host review (head side only), and render.
---
--- review_repository.attach() may read revision/working-tree content
--- (parley.runtime.fs), which yields internally; run it inside a plenary
--- coroutine so that's safe from a plain `User` autocmd callback (mirrors
--- services/read.lua's do_refresh, which does the same for BufEnter).
--- @param bufnr integer
function M._on_diff_buf(bufnr)
  local config = M._get_config()
  if not config or not config.diffview or not config.diffview.enabled then
    return
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local file = M._resolve_file(bufnr)
  if not file then
    return
  end

  local root = M._derive_root(file)
  local host_bufnr, review_key, host_ctx = M._find_host(root)
  if not review_key then
    return
  end

  local host_snapshot = review_repository.get(host_bufnr)
  if not host_snapshot or not host_snapshot.review then
    return
  end

  if not M._is_head_side(file, host_snapshot.review.head_sha) then
    -- Base/old-side diff buffers have nothing to render: parley never
    -- anchors discussions to side == "old".
    return
  end

  local provider_snapshot = provider_repository.get(host_bufnr)
  if not provider_snapshot then
    return
  end

  context_repository.set(bufnr, {
    kind = "regular",
    bufnr = bufnr,
    path = nil,
    vcs_info = host_ctx.vcs_info,
    status = "ready",
    rel_path = file.path,
  })
  provider_repository.set(bufnr, provider_snapshot)

  async.run(function()
    local snapshot = review_repository.attach(bufnr, review_key)
    vim.schedule(function()
      if not snapshot or not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      M._attached[bufnr] = true
      read_service.render_snapshot(bufnr, snapshot)
      set_new_comment_keymap(bufnr, config.keymaps and config.keymaps.diffview_new_comment)
    end)
  end)
end

-- ---------------------------------------------------------------------------
-- File panel badges
-- ---------------------------------------------------------------------------

M._panel_ns = nil
--- @return integer
local function panel_ns()
  if not M._panel_ns then
    M._panel_ns = vim.api.nvim_create_namespace("parley_diffview_panel")
  end
  return M._panel_ns
end

--- Render comment-count badges next to changed files in the diffview file
--- panel, matched by searching the panel buffer's rendered text for each
--- file's basename (the panel has no addressable per-entry line API).
function M._render_panel_badges()
  local config = M._get_config()
  if not config or not config.diffview or not config.diffview.enabled or not config.diffview.file_panel_badges then
    return
  end
  local lib = M._get_lib()
  if not lib then
    return
  end
  local ok, view = pcall(lib.get_current_view)
  if not ok or not view or not view.panel or not view.panel.winid then
    return
  end
  if not vim.api.nvim_win_is_valid(view.panel.winid) then
    return
  end
  local panel_bufnr = vim.api.nvim_win_get_buf(view.panel.winid)
  local ns = panel_ns()
  vim.api.nvim_buf_clear_namespace(panel_bufnr, ns, 0, -1)
  if not view.panel.files or not view.panel.files.iter then
    return
  end

  -- Find any host buffer with an active review to source discussion counts
  -- from; file panel entries aren't tied to a single diff buffer. Derive the
  -- VCS root from the first panel entry (same technique as a diff buffer's
  -- own identity resolution) since the view/adapter don't expose it directly.
  local root
  for _, file in view.panel.files:iter() do
    root = M._derive_root(file)
    if root then
      break
    end
  end
  local host_bufnr, review_key = M._find_host(root)
  if not review_key then
    return
  end
  local host_snapshot = review_repository.get(host_bufnr)
  if not host_snapshot or not host_snapshot.all_discussions then
    return
  end

  local by_file = {}
  for _, discussion in ipairs(host_snapshot.all_discussions) do
    if type(discussion.file) == "string" then
      local entry = by_file[discussion.file]
      if not entry then
        entry = { count = 0, unresolved = false }
        by_file[discussion.file] = entry
      end
      entry.count = entry.count + 1
      if require("parley.discussion").is_open_issue(discussion) then
        entry.unresolved = true
      end
    end
  end
  if next(by_file) == nil then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(panel_bufnr, 0, -1, false)
  local used_lines = {}
  for _, file in view.panel.files:iter() do
    local entry = file.path and by_file[file.path]
    if entry then
      local needle = vim.fs.basename(file.path)
      for lnum, text in ipairs(lines) do
        if not used_lines[lnum] and text:find(needle, 1, true) then
          used_lines[lnum] = true
          local badge = string.format("💬%d%s", entry.count, entry.unresolved and "!" or "")
          vim.api.nvim_buf_set_extmark(panel_bufnr, ns, lnum - 1, 0, {
            virt_text = { { " " .. badge, "ParleyVirtualTextMeta" } },
            virt_text_pos = "eol",
          })
          break
        end
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

--- @param augroup integer
function M.setup(augroup)
  vim.api.nvim_create_autocmd("User", {
    group = augroup,
    pattern = { "DiffviewDiffBufRead", "DiffviewDiffBufWinEnter" },
    callback = function()
      M._on_diff_buf(vim.api.nvim_get_current_buf())
    end,
    desc = "Parley: render PR discussions in diffview diff buffers",
  })

  vim.api.nvim_create_autocmd("User", {
    group = augroup,
    pattern = { "DiffviewViewPostLayout", "DiffviewSelectionChanged", "DiffviewFilesStaged" },
    callback = M._render_panel_badges,
    desc = "Parley: render comment-count badges in the diffview file panel",
  })
end

return M
