--- Tests for parley.diffview_integration — PR discussions inside diffview-plus.nvim.
--- Run via: make test

local a = require("plenary.async").tests
local diffview_integration = require("parley.diffview_integration")
local context_repository = require("parley.repositories.context")
local provider_repository = require("parley.repositories.provider")
local review_repository = require("parley.repositories.review")

-- ---------------------------------------------------------------------------
-- Pure helpers
-- ---------------------------------------------------------------------------

a.describe("parley.diffview_integration._derive_root", function()
  a.it("derives the VCS root when absolute_path ends with /path", function()
    local root = diffview_integration._derive_root({ absolute_path = "/repo/lua/foo.lua", path = "lua/foo.lua" })
    assert.equals("/repo", root)
  end)

  a.it("returns nil when absolute_path doesn't end with /path", function()
    local root = diffview_integration._derive_root({ absolute_path = "/repo/other.lua", path = "lua/foo.lua" })
    assert.is_nil(root)
  end)

  a.it("returns nil when fields are missing", function()
    assert.is_nil(diffview_integration._derive_root({}))
  end)
end)

a.describe("parley.diffview_integration._is_head_side", function()
  a.it("is true for a LOCAL revision regardless of head_sha", function()
    assert.is_true(diffview_integration._is_head_side({ rev = { type = "LOCAL" } }, "deadbeef"))
  end)

  a.it("is true when the revision commit matches head_sha", function()
    assert.is_true(diffview_integration._is_head_side({ rev = { type = "COMMIT", commit = "abc123" } }, "abc123"))
  end)

  a.it("is false when the revision commit does not match head_sha", function()
    assert.is_false(diffview_integration._is_head_side({ rev = { type = "COMMIT", commit = "abc123" } }, "other"))
  end)

  a.it("is false when there is no revision", function()
    assert.is_false(diffview_integration._is_head_side({}, "abc123"))
  end)

  a.it("is false when head_sha is empty", function()
    assert.is_false(diffview_integration._is_head_side({ rev = { type = "COMMIT", commit = "" } }, ""))
  end)
end)

a.describe("parley.diffview_integration._matches_old_side", function()
  local function old_side_discussion(id, file, revision, line)
    return {
      id = id,
      file = file,
      line = line,
      anchor = { kind = "inline", path = file, side = "old", revision = revision, line = line },
    }
  end

  a.it("is true when a discussion's old-side anchor revision matches the file's revision", function()
    local file = { path = "a.lua", rev = { type = "COMMIT", commit = "base-sha" } }
    local discussions = { old_side_discussion("d1", "a.lua", "base-sha", 5) }
    assert.is_true(diffview_integration._matches_old_side(file, discussions))
  end)

  a.it("is false when no discussion's revision matches (unrelated diff)", function()
    local file = { path = "a.lua", rev = { type = "COMMIT", commit = "unrelated-sha" } }
    local discussions = { old_side_discussion("d1", "a.lua", "base-sha", 5) }
    assert.is_false(diffview_integration._matches_old_side(file, discussions))
  end)

  a.it("is false when the matching discussion is for a different file", function()
    local file = { path = "b.lua", rev = { type = "COMMIT", commit = "base-sha" } }
    local discussions = { old_side_discussion("d1", "a.lua", "base-sha", 5) }
    assert.is_false(diffview_integration._matches_old_side(file, discussions))
  end)

  a.it("is false for a new-side discussion even if the revision happens to match", function()
    local file = { path = "a.lua", rev = { type = "COMMIT", commit = "head-sha" } }
    local discussions = {
      { id = "d1", file = "a.lua", line = 5, anchor = { kind = "inline", path = "a.lua", line = 5 } },
    }
    assert.is_false(diffview_integration._matches_old_side(file, discussions))
  end)

  a.it("is false when the file has no revision", function()
    assert.is_false(diffview_integration._matches_old_side({ path = "a.lua" }, {}))
  end)

  a.it("is false with no discussions", function()
    local file = { path = "a.lua", rev = { type = "COMMIT", commit = "base-sha" } }
    assert.is_false(diffview_integration._matches_old_side(file, {}))
  end)
end)

-- ---------------------------------------------------------------------------
-- _find_host / _on_diff_buf — exercised against real repository state
-- ---------------------------------------------------------------------------

--- @type parley.VcsInfo
local SAMPLE_VCS = {
  vcs = "git",
  root = "/repo",
  branch = "main",
  remote_url = "https://github.com/org/repo.git",
}

local function make_host_buffer(review_key, shared)
  local host_bufnr = vim.api.nvim_create_buf(false, true)
  context_repository.set(host_bufnr, {
    kind = "regular",
    bufnr = host_bufnr,
    path = "/repo/lua/foo.lua",
    vcs_info = SAMPLE_VCS,
    status = "ready",
    rel_path = "lua/foo.lua",
  })
  provider_repository.set(host_bufnr, { provider = { display_name = "test" }, opts = {} })
  review_repository._reviews[review_key] = shared
  review_repository._bufnr_key[host_bufnr] = review_key
  review_repository._key_bufnrs[review_key] = { [host_bufnr] = true }
  return host_bufnr
end

local function cleanup_buffer(bufnr)
  if not bufnr then
    return
  end
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end
  context_repository.invalidate(bufnr)
  provider_repository.invalidate(bufnr)
end

a.describe("parley.diffview_integration._find_host", function()
  local host_bufnr, review_key

  a.after_each(function()
    cleanup_buffer(host_bufnr)
    if review_key then
      review_repository._reviews[review_key] = nil
      review_repository._bufnr_key[host_bufnr] = nil
      review_repository._key_bufnrs[review_key] = nil
    end
  end)

  a.it("finds a loaded regular buffer with an active review under the given root", function()
    review_key = "test-key-1"
    host_bufnr = make_host_buffer(review_key, { review = { head_sha = "abc123" }, all_discussions = {} })

    local found_bufnr, found_key = diffview_integration._find_host("/repo")

    assert.equals(host_bufnr, found_bufnr)
    assert.equals(review_key, found_key)
  end)

  a.it("returns nil when no buffer matches the root", function()
    local found_bufnr = diffview_integration._find_host("/no/such/repo")
    assert.is_nil(found_bufnr)
  end)

  a.it("returns nil when root is nil", function()
    assert.is_nil(diffview_integration._find_host(nil))
  end)
end)

a.describe("parley.diffview_integration._on_diff_buf", function()
  local host_bufnr, diff_bufnr, review_key
  local orig_get_config, orig_resolve_file, orig_render_snapshot

  a.before_each(function()
    orig_get_config = diffview_integration._get_config
    orig_resolve_file = diffview_integration._resolve_file
    orig_render_snapshot = require("parley.services.read").render_snapshot
    diffview_integration._get_config = function()
      return { diffview = { enabled = true }, keymaps = { diffview_new_comment = "" } }
    end
  end)

  a.after_each(function()
    diffview_integration._get_config = orig_get_config
    diffview_integration._resolve_file = orig_resolve_file
    require("parley.services.read").render_snapshot = orig_render_snapshot
    diffview_integration._attached[diff_bufnr] = nil
    cleanup_buffer(host_bufnr)
    cleanup_buffer(diff_bufnr)
    if review_key then
      review_repository._reviews[review_key] = nil
      review_repository._bufnr_key[host_bufnr] = nil
      review_repository._key_bufnrs[review_key] = nil
    end
  end)

  a.it("aliases a head-side diff buffer onto the host review and renders it", function()
    review_key = "test-key-2"
    host_bufnr = make_host_buffer(review_key, {
      review = { head_sha = "abc123" },
      all_discussions = {
        { id = "d1", file = "lua/foo.lua", line = 5, anchor = { kind = "inline", path = "lua/foo.lua", line = 5 } },
      },
    })
    diff_bufnr = vim.api.nvim_create_buf(false, true)
    diffview_integration._resolve_file = function(bufnr)
      if bufnr ~= diff_bufnr then
        return nil
      end
      return {
        bufnr = diff_bufnr,
        path = "lua/foo.lua",
        absolute_path = "/repo/lua/foo.lua",
        rev = { type = "COMMIT", commit = "abc123" },
      }
    end

    local rendered_bufnr, rendered_snapshot
    require("parley.services.read").render_snapshot = function(bufnr, snapshot)
      rendered_bufnr, rendered_snapshot = bufnr, snapshot
    end

    diffview_integration._on_diff_buf(diff_bufnr)
    vim.wait(1000, function()
      return rendered_bufnr ~= nil
    end, 10)

    assert.is_true(diffview_integration._attached[diff_bufnr])
    assert.equals(diff_bufnr, rendered_bufnr)
    assert.is_not_nil(rendered_snapshot)
    assert.equals("lua/foo.lua", context_repository.get(diff_bufnr).rel_path)
    assert.equals(review_key, review_repository.key_for_bufnr(diff_bufnr))
  end)

  a.it("does nothing for a base/old-side diff buffer with no discussion anchored there", function()
    review_key = "test-key-3"
    host_bufnr = make_host_buffer(review_key, { review = { head_sha = "abc123" }, all_discussions = {} })
    diff_bufnr = vim.api.nvim_create_buf(false, true)
    diffview_integration._resolve_file = function(bufnr)
      if bufnr ~= diff_bufnr then
        return nil
      end
      return {
        bufnr = diff_bufnr,
        path = "lua/foo.lua",
        absolute_path = "/repo/lua/foo.lua",
        rev = { type = "COMMIT", commit = "base-sha" },
      }
    end

    local rendered = false
    require("parley.services.read").render_snapshot = function()
      rendered = true
    end

    diffview_integration._on_diff_buf(diff_bufnr)

    assert.is_false(rendered)
    assert.is_nil(diffview_integration._attached[diff_bufnr])
  end)

  a.it("aliases a base/old-side diff buffer with identity mapping when a discussion is anchored there", function()
    review_key = "test-key-old-side"
    host_bufnr = make_host_buffer(review_key, {
      review = { head_sha = "abc123" },
      all_discussions = {
        {
          id = "d1",
          file = "lua/foo.lua",
          line = 5,
          anchor = { kind = "inline", path = "lua/foo.lua", side = "old", revision = "base-sha", line = 5 },
        },
      },
    })
    diff_bufnr = vim.api.nvim_create_buf(false, true)
    diffview_integration._resolve_file = function(bufnr)
      if bufnr ~= diff_bufnr then
        return nil
      end
      return {
        bufnr = diff_bufnr,
        path = "lua/foo.lua",
        absolute_path = "/repo/lua/foo.lua",
        rev = { type = "COMMIT", commit = "base-sha" },
      }
    end

    local rendered_bufnr, rendered_snapshot
    require("parley.services.read").render_snapshot = function(bufnr, snapshot)
      rendered_bufnr, rendered_snapshot = bufnr, snapshot
    end

    diffview_integration._on_diff_buf(diff_bufnr)
    vim.wait(1000, function()
      return rendered_bufnr ~= nil
    end, 10)

    assert.is_true(diffview_integration._attached[diff_bufnr])
    assert.equals(diff_bufnr, rendered_bufnr)
    assert.equals(5, rendered_snapshot.mappings.d1.local_line)
    assert.equals("old", review_repository._identity_bufnrs[diff_bufnr])
  end)

  a.it("does not wire the new-comment keymap for an old-side diff buffer", function()
    review_key = "test-key-old-side-keymap"
    host_bufnr = make_host_buffer(review_key, {
      review = { head_sha = "abc123" },
      all_discussions = {
        {
          id = "d1",
          file = "lua/foo.lua",
          line = 5,
          anchor = { kind = "inline", path = "lua/foo.lua", side = "old", revision = "base-sha", line = 5 },
        },
      },
    })
    diff_bufnr = vim.api.nvim_create_buf(false, true)
    diffview_integration._resolve_file = function(bufnr)
      if bufnr ~= diff_bufnr then
        return nil
      end
      return {
        bufnr = diff_bufnr,
        path = "lua/foo.lua",
        absolute_path = "/repo/lua/foo.lua",
        rev = { type = "COMMIT", commit = "base-sha" },
      }
    end
    diffview_integration._get_config = function()
      return { diffview = { enabled = true }, keymaps = { diffview_new_comment = "<leader>pc" } }
    end
    local rendered = false
    require("parley.services.read").render_snapshot = function()
      rendered = true
    end

    diffview_integration._on_diff_buf(diff_bufnr)
    vim.wait(1000, function()
      return rendered
    end, 10)

    local ok = pcall(vim.api.nvim_buf_get_keymap, diff_bufnr, "n")
    local has_keymap = false
    if ok then
      for _, map in ipairs(vim.api.nvim_buf_get_keymap(diff_bufnr, "n")) do
        if map.lhs == "<leader>pc" then
          has_keymap = true
        end
      end
    end
    assert.is_false(has_keymap)
  end)

  a.it("does nothing when diffview integration is disabled", function()
    diffview_integration._get_config = function()
      return { diffview = { enabled = false } }
    end
    diff_bufnr = vim.api.nvim_create_buf(false, true)
    local resolve_called = false
    diffview_integration._resolve_file = function()
      resolve_called = true
    end

    diffview_integration._on_diff_buf(diff_bufnr)

    assert.is_false(resolve_called)
  end)
end)

-- ---------------------------------------------------------------------------
-- review_repository identity-mapping regression
--
-- A diffview head-side buffer's content is byte-identical to the review's
-- head revision, so cursor-line-based actions (open/reply/resolve/react)
-- must resolve discussions by identity (PR-diff-space line == buffer line).
-- Before this fix, review_repository.attach() went through the same
-- working-tree-relative local_mappings cache regular buffers use, which is
-- only coincidentally correct when the working tree is clean.
-- ---------------------------------------------------------------------------

a.describe("parley.diffview_integration review_repository identity mapping", function()
  local local_mappings = require("parley.repositories.local_mappings")
  local host_bufnr, diff_bufnr, review_key
  local orig_local_mappings_get

  a.before_each(function()
    orig_local_mappings_get = local_mappings.get
  end)

  a.after_each(function()
    local_mappings.get = orig_local_mappings_get
    review_repository._identity_bufnrs[diff_bufnr] = nil
    cleanup_buffer(host_bufnr)
    cleanup_buffer(diff_bufnr)
    if review_key then
      review_repository._reviews[review_key] = nil
      review_repository._bufnr_key[host_bufnr] = nil
      review_repository._bufnr_key[diff_bufnr] = nil
      review_repository._key_bufnrs[review_key] = nil
    end
  end)

  a.it(
    "keeps identity mapping for a diffview-attached buffer even when local_mappings would shift the line, "
      .. "including after a background refresh recomputes sibling buffers",
    function()
      review_key = "identity-regression-1"
      host_bufnr = make_host_buffer(review_key, {
        review = { head_sha = "abc123" },
        all_discussions = {
          {
            id = "d1",
            file = "lua/foo.lua",
            line = 5,
            anchor = { kind = "inline", path = "lua/foo.lua", line = 5 },
          },
        },
      })

      diff_bufnr = vim.api.nvim_create_buf(false, true)
      context_repository.set(diff_bufnr, {
        kind = "regular",
        bufnr = diff_bufnr,
        path = nil,
        vcs_info = SAMPLE_VCS,
        status = "ready",
        rel_path = "lua/foo.lua",
      })

      local snapshot = review_repository.attach(diff_bufnr, review_key)
      assert.equals(5, snapshot.mappings.d1.local_line)

      -- Simulate a dirty working tree: local_mappings would shift line 5 to
      -- line 9 for any buffer using the ordinary working-tree-relative path.
      local_mappings.get = function()
        return { d1 = { local_line = 9, confidence = 0, stale = true } }
      end

      -- Trigger the same recomputation a background refresh would: this
      -- invalidates local_mappings and recomputes every buffer attached to
      -- review_key whose vcs_info matches (host_bufnr and diff_bufnr both).
      review_repository.remap_async(host_bufnr)
      vim.wait(1000, function()
        local host_snapshot = review_repository.get(host_bufnr)
        return host_snapshot and host_snapshot.mappings.d1 and host_snapshot.mappings.d1.local_line == 9
      end, 20)

      -- Regular buffer: picks up the shifted, working-tree-relative mapping.
      assert.equals(9, review_repository.get(host_bufnr).mappings.d1.local_line)
      -- Diffview-identity buffer: stays at identity, unaffected — proving
      -- the fix is scoped per-bufnr, not a global disable of local_mappings.
      assert.equals(5, review_repository.get(diff_bufnr).mappings.d1.local_line)
    end
  )

  a.it("attach(..., side) only includes discussions anchored to that side", function()
    review_key = "identity-side-1"
    host_bufnr = make_host_buffer(review_key, {
      review = { head_sha = "abc123" },
      all_discussions = {
        {
          id = "new1",
          file = "lua/foo.lua",
          line = 3,
          anchor = { kind = "inline", path = "lua/foo.lua", line = 3 },
        },
        {
          id = "old1",
          file = "lua/foo.lua",
          line = 7,
          anchor = { kind = "inline", path = "lua/foo.lua", side = "old", revision = "base-sha", line = 7 },
        },
      },
    })

    local new_bufnr = vim.api.nvim_create_buf(false, true)
    context_repository.set(new_bufnr, {
      kind = "regular",
      bufnr = new_bufnr,
      path = nil,
      vcs_info = SAMPLE_VCS,
      status = "ready",
      rel_path = "lua/foo.lua",
    })
    local old_bufnr = vim.api.nvim_create_buf(false, true)
    context_repository.set(old_bufnr, {
      kind = "regular",
      bufnr = old_bufnr,
      path = nil,
      vcs_info = SAMPLE_VCS,
      status = "ready",
      rel_path = "lua/foo.lua",
    })

    local new_snapshot = review_repository.attach(new_bufnr, review_key, "new")
    local old_snapshot = review_repository.attach(old_bufnr, review_key, "old")

    assert.is_not_nil(new_snapshot.mappings.new1)
    assert.is_nil(new_snapshot.mappings.old1)
    assert.is_nil(old_snapshot.mappings.new1)
    assert.is_not_nil(old_snapshot.mappings.old1)
    assert.equals(7, old_snapshot.mappings.old1.local_line)

    cleanup_buffer(new_bufnr)
    cleanup_buffer(old_bufnr)
    review_repository._identity_bufnrs[new_bufnr] = nil
    review_repository._identity_bufnrs[old_bufnr] = nil
    review_repository._bufnr_key[new_bufnr] = nil
    review_repository._bufnr_key[old_bufnr] = nil
  end)
end)

-- ---------------------------------------------------------------------------
-- :Parley diffview open|close|toggle
-- ---------------------------------------------------------------------------

--- @return parley.VcsAdapter
local function stub_vcs_adapter(diffview_range)
  return {
    head = function()
      return {}
    end,
    show = function()
      return {}
    end,
    status = function()
      return {}
    end,
    dirty = function()
      return false
    end,
    diff = function()
      return {}
    end,
    diffview_range = diffview_range,
  }
end

--- @return table[] calls, table dv_stub
local function make_dv_stub()
  local calls = {}
  return calls,
    {
      open = function(args)
        calls[#calls + 1] = { "open", args }
      end,
      close = function()
        calls[#calls + 1] = { "close" }
      end,
    }
end

a.describe("parley.diffview_integration open/close/toggle", function()
  local adapters = require("parley.vcs.adapters")
  local host_bufnr, review_key
  local orig_get_diffview_api, orig_notify, orig_get_lib

  a.before_each(function()
    adapters.reset()
    orig_get_diffview_api = diffview_integration._get_diffview_api
    orig_notify = diffview_integration._notify
    orig_get_lib = diffview_integration._get_lib
  end)

  a.after_each(function()
    diffview_integration._get_diffview_api = orig_get_diffview_api
    diffview_integration._notify = orig_notify
    diffview_integration._get_lib = orig_get_lib
    adapters.reset()
    cleanup_buffer(host_bufnr)
    if review_key then
      review_repository._reviews[review_key] = nil
      review_repository._bufnr_key[host_bufnr] = nil
      review_repository._key_bufnrs[review_key] = nil
    end
    host_bufnr, review_key = nil, nil
  end)

  a.it("open: resolves the base...head range via the VCS adapter and opens diffview", function()
    review_key = "diffview-open-1"
    host_bufnr = make_host_buffer(review_key, {
      review = { head_sha = "abc123", pr = { base_branch = "main" } },
      all_discussions = {},
    })
    adapters.register(
      "git",
      stub_vcs_adapter(function(base, head)
        return { base .. "..." .. head, "--imply-local" }
      end)
    )
    local calls, dv = make_dv_stub()
    diffview_integration._get_diffview_api = function()
      return dv
    end

    diffview_integration.open(host_bufnr)

    assert.same({ { "open", { "main...abc123", "--imply-local" } } }, calls)
  end)

  a.it("open: notifies and does nothing when diffview isn't installed", function()
    diffview_integration._get_diffview_api = function()
      return nil
    end
    local messages = {}
    diffview_integration._notify = function(msg, level)
      messages[#messages + 1] = { msg, level }
    end

    diffview_integration.open(1)

    assert.equals(1, #messages)
  end)

  a.it("open: notifies and does nothing when the VCS adapter has no diffview_range", function()
    review_key = "diffview-open-2"
    host_bufnr = make_host_buffer(review_key, {
      review = { head_sha = "abc123", pr = { base_branch = "main" } },
      all_discussions = {},
    })
    adapters.register("git", stub_vcs_adapter(nil))
    local calls, dv = make_dv_stub()
    diffview_integration._get_diffview_api = function()
      return dv
    end
    local messages = {}
    diffview_integration._notify = function(msg, level)
      messages[#messages + 1] = { msg, level }
    end

    diffview_integration.open(host_bufnr)

    assert.equals(0, #calls)
    assert.equals(1, #messages)
  end)

  a.it("open: notifies when base branch or head commit is missing", function()
    review_key = "diffview-open-3"
    host_bufnr = make_host_buffer(review_key, {
      review = { head_sha = "", pr = { base_branch = "main" } },
      all_discussions = {},
    })
    adapters.register(
      "git",
      stub_vcs_adapter(function(base, head)
        return { base, head }
      end)
    )
    local calls, dv = make_dv_stub()
    diffview_integration._get_diffview_api = function()
      return dv
    end
    local messages = {}
    diffview_integration._notify = function(msg, level)
      messages[#messages + 1] = { msg, level }
    end

    diffview_integration.open(host_bufnr)

    assert.equals(0, #calls)
    assert.equals(1, #messages)
  end)

  a.it("close: closes diffview when installed", function()
    local calls, dv = make_dv_stub()
    diffview_integration._get_diffview_api = function()
      return dv
    end

    diffview_integration.close(1)

    assert.same({ { "close" } }, calls)
  end)

  a.it("close: no-ops when diffview isn't installed", function()
    diffview_integration._get_diffview_api = function()
      return nil
    end

    diffview_integration.close(1)
  end)

  a.it("toggle: closes an already-open view without resolving a range for the buffer", function()
    local calls, dv = make_dv_stub()
    diffview_integration._get_diffview_api = function()
      return dv
    end
    diffview_integration._get_lib = function()
      return {
        get_current_view = function()
          return { fake = true }
        end,
      }
    end

    -- bufnr 999 has no review context at all; toggle must not touch it
    -- because a view is already open, so close must win regardless.
    diffview_integration.toggle(999)

    assert.same({ { "close" } }, calls)
  end)

  a.it("toggle: opens scoped to the review when no view is currently open", function()
    review_key = "diffview-toggle-1"
    host_bufnr = make_host_buffer(review_key, {
      review = { head_sha = "abc123", pr = { base_branch = "main" } },
      all_discussions = {},
    })
    adapters.register(
      "git",
      stub_vcs_adapter(function(base, head)
        return { base .. "..." .. head }
      end)
    )
    local calls, dv = make_dv_stub()
    diffview_integration._get_diffview_api = function()
      return dv
    end
    diffview_integration._get_lib = function()
      return {
        get_current_view = function()
          return nil
        end,
      }
    end

    diffview_integration.toggle(host_bufnr)

    assert.same({ { "open", { "main...abc123" } } }, calls)
  end)
end)

-- ---------------------------------------------------------------------------
-- _render_panel_badges — component-tree identity matching, not text search
-- ---------------------------------------------------------------------------

local PANEL_NS = vim.api.nvim_create_namespace("parley_diffview_panel")

--- @param listing_style "list"|"tree"
--- @param components table fake FilePanel.components
--- @param files table[] fake vcs.File list, order defines view.panel.files:iter()
--- @return table view, integer panel_bufnr
local function make_panel_view(listing_style, components, files)
  local panel_bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(panel_bufnr, 0, -1, false, { "l1", "l2", "l3", "l4", "l5" })
  local panel_winid = vim.api.nvim_open_win(panel_bufnr, false, {
    relative = "editor",
    row = 0,
    col = 0,
    width = 10,
    height = 5,
    style = "minimal",
    noautocmd = true,
  })
  return {
    panel = {
      winid = panel_winid,
      listing_style = listing_style,
      components = components,
      files = {
        iter = function()
          local i = 0
          return function()
            i = i + 1
            if files[i] then
              return i, files[i]
            end
          end
        end,
      },
    },
  },
    panel_bufnr
end

--- A fake tree-style root RenderComponent: `deep_some` walks a fixed list
--- of leaf { context = ... } tables, matching RenderComponent:deep_some's
--- contract (callback returning true stops the walk).
--- @param leaves table[]
local function fake_tree_root(leaves)
  return {
    deep_some = function(_self, callback)
      for _, leaf in ipairs(leaves) do
        if callback(leaf) then
          return true
        end
      end
      return false
    end,
  }
end

a.describe("parley.diffview_integration._render_panel_badges", function()
  local host_bufnr, review_key, panel_winid
  local orig_get_config, orig_get_lib, orig_find_host

  a.before_each(function()
    orig_get_config = diffview_integration._get_config
    orig_get_lib = diffview_integration._get_lib
    orig_find_host = diffview_integration._find_host
    diffview_integration._get_config = function()
      return { diffview = { enabled = true, file_panel_badges = true } }
    end
  end)

  a.after_each(function()
    diffview_integration._get_config = orig_get_config
    diffview_integration._get_lib = orig_get_lib
    diffview_integration._find_host = orig_find_host
    if panel_winid and vim.api.nvim_win_is_valid(panel_winid) then
      vim.api.nvim_win_close(panel_winid, true)
    end
    panel_winid = nil
    cleanup_buffer(host_bufnr)
    if review_key then
      review_repository._reviews[review_key] = nil
      review_repository._bufnr_key[host_bufnr] = nil
      review_repository._key_bufnrs[review_key] = nil
    end
  end)

  --- @param view table
  local function stub_view(view)
    diffview_integration._get_lib = function()
      return {
        get_current_view = function()
          return view
        end,
      }
    end
  end

  --- Seed a host review with discussions for the given files.
  --- @param files_with_discussions string[]
  local function seed_review(files_with_discussions)
    review_key = "panel-badge-key"
    local all_discussions = {}
    for _, path in ipairs(files_with_discussions) do
      all_discussions[#all_discussions + 1] = { id = path, file = path, line = 1 }
    end
    host_bufnr = make_host_buffer(review_key, {
      review = { head_sha = "abc123" },
      all_discussions = all_discussions,
    })
    diffview_integration._find_host = function()
      return host_bufnr, review_key
    end
  end

  a.it(
    "places each same-basename file's badge on its OWN row (list style) — "
      .. "the exact case text-matching got wrong",
    function()
      local file_a = { path = "a/foo.lua", absolute_path = "/repo/a/foo.lua" }
      local file_b = { path = "b/foo.lua", absolute_path = "/repo/b/foo.lua" }
      seed_review({ "a/foo.lua", "b/foo.lua" })

      local view, panel_bufnr = make_panel_view("list", {
        conflicting = { files = {} },
        working = {
          files = {
            { comp = { context = file_a, lstart = 1 } },
            { comp = { context = file_b, lstart = 3 } },
          },
        },
        staged = { files = {} },
      }, { file_a, file_b })
      panel_winid = view.panel.winid
      stub_view(view)

      diffview_integration._render_panel_badges()

      local marks = vim.api.nvim_buf_get_extmarks(panel_bufnr, PANEL_NS, 0, -1, {})
      local rows = {}
      for _, mark in ipairs(marks) do
        rows[#rows + 1] = mark[2]
      end
      table.sort(rows)
      assert.same({ 1, 3 }, rows)
    end
  )

  a.it("finds the file's row via deep_some (tree style)", function()
    local file_a = { path = "a/foo.lua", absolute_path = "/repo/a/foo.lua" }
    seed_review({ "a/foo.lua" })

    local view, panel_bufnr = make_panel_view("tree", {
      conflicting = { files = { comp = fake_tree_root({}) } },
      working = { files = { comp = fake_tree_root({ { context = file_a, lstart = 2 } }) } },
      staged = { files = { comp = fake_tree_root({}) } },
    }, { file_a })
    panel_winid = view.panel.winid
    stub_view(view)

    diffview_integration._render_panel_badges()

    local marks = vim.api.nvim_buf_get_extmarks(panel_bufnr, PANEL_NS, 0, -1, {})
    assert.equals(1, #marks)
    assert.equals(2, marks[1][2])
  end)

  a.it("skips a file with no discussions", function()
    local file_a = { path = "a/foo.lua", absolute_path = "/repo/a/foo.lua" }
    local file_c = { path = "c/bar.lua", absolute_path = "/repo/c/bar.lua" }
    seed_review({ "a/foo.lua" })

    local view, panel_bufnr = make_panel_view("list", {
      conflicting = { files = {} },
      working = {
        files = {
          { comp = { context = file_a, lstart = 1 } },
          { comp = { context = file_c, lstart = 2 } },
        },
      },
      staged = { files = {} },
    }, { file_a, file_c })
    panel_winid = view.panel.winid
    stub_view(view)

    diffview_integration._render_panel_badges()

    local marks = vim.api.nvim_buf_get_extmarks(panel_bufnr, PANEL_NS, 0, -1, {})
    assert.equals(1, #marks)
    assert.equals(1, marks[1][2])
  end)

  a.it(
    "skips a file with discussions whose row can't be found (e.g. a collapsed directory), without erroring",
    function()
      local file_a = { path = "a/foo.lua", absolute_path = "/repo/a/foo.lua" }
      seed_review({ "a/foo.lua" })

      -- file_a has a discussion but no matching component anywhere in the tree.
      local view, panel_bufnr = make_panel_view("list", {
        conflicting = { files = {} },
        working = { files = {} },
        staged = { files = {} },
      }, { file_a })
      panel_winid = view.panel.winid
      stub_view(view)

      diffview_integration._render_panel_badges()

      local marks = vim.api.nvim_buf_get_extmarks(panel_bufnr, PANEL_NS, 0, -1, {})
      assert.equals(0, #marks)
    end
  )
end)

-- ---------------------------------------------------------------------------
-- goto_file — cross-file review navigation from a diffview buffer
-- ---------------------------------------------------------------------------

a.describe("parley.diffview_integration.goto_file", function()
  local winid, bufnr
  local orig_get_lib, orig_resolve_file

  a.before_each(function()
    orig_get_lib = diffview_integration._get_lib
    orig_resolve_file = diffview_integration._resolve_file
  end)

  a.after_each(function()
    diffview_integration._get_lib = orig_get_lib
    diffview_integration._resolve_file = orig_resolve_file
    if bufnr then
      diffview_integration._attached[bufnr] = nil
    end
    if winid and vim.api.nvim_win_is_valid(winid) then
      vim.api.nvim_win_close(winid, true)
    end
    winid, bufnr = nil, nil
  end)

  --- Real scratch window/buffer standing in for the head-side diff window
  --- goto_file is expected to find and focus.
  local function make_target_window(line_count)
    bufnr = vim.api.nvim_create_buf(false, true)
    local lines = {}
    for i = 1, line_count do
      lines[i] = "l" .. i
    end
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    winid = vim.api.nvim_open_win(bufnr, false, {
      relative = "editor",
      row = 0,
      col = 0,
      width = 10,
      height = line_count,
      style = "minimal",
      noautocmd = true,
    })
    return winid, bufnr
  end

  a.it("switches to the target file's head-side window and places the cursor", function()
    make_target_window(10)
    local set_file_calls = {}
    local view = {
      set_file_by_path = function(_self, path, focus, highlight)
        set_file_calls[#set_file_calls + 1] = { path = path, focus = focus, highlight = highlight }
      end,
    }
    diffview_integration._get_lib = function()
      return {
        get_current_view = function()
          return view
        end,
      }
    end
    diffview_integration._resolve_file = function(b)
      if b ~= bufnr then
        return nil
      end
      return { path = "b/target.lua", rev = { type = "COMMIT", commit = "headsha" } }
    end
    diffview_integration._attached[bufnr] = true

    local ok = diffview_integration.goto_file("b/target.lua", 5, "headsha", 500)

    assert.is_true(ok)
    assert.equals(1, #set_file_calls)
    assert.equals("b/target.lua", set_file_calls[1].path)
    assert.equals(winid, vim.api.nvim_get_current_win())
    assert.equals(5, vim.api.nvim_win_get_cursor(winid)[1])
  end)

  a.it("clamps target_line to the buffer's line count", function()
    make_target_window(3)
    diffview_integration._get_lib = function()
      return {
        get_current_view = function()
          return { set_file_by_path = function() end }
        end,
      }
    end
    diffview_integration._resolve_file = function(b)
      if b ~= bufnr then
        return nil
      end
      return { path = "b/target.lua", rev = { type = "COMMIT", commit = "headsha" } }
    end
    diffview_integration._attached[bufnr] = true

    local ok = diffview_integration.goto_file("b/target.lua", 999, "headsha", 500)

    assert.is_true(ok)
    assert.equals(3, vim.api.nvim_win_get_cursor(winid)[1])
  end)

  a.it("returns false when diffview isn't installed", function()
    diffview_integration._get_lib = function()
      return nil
    end

    assert.is_false(diffview_integration.goto_file("b/target.lua", 5, "headsha", 500))
  end)

  a.it("returns false when the current view has no set_file_by_path (not a DiffView)", function()
    diffview_integration._get_lib = function()
      return {
        get_current_view = function()
          return { some_other_field = true }
        end,
      }
    end

    assert.is_false(diffview_integration.goto_file("b/target.lua", 5, "headsha", 500))
  end)

  a.it("returns false when no matching head-side window appears within the timeout", function()
    diffview_integration._get_lib = function()
      return {
        get_current_view = function()
          return { set_file_by_path = function() end }
        end,
      }
    end
    diffview_integration._resolve_file = function()
      return nil
    end

    assert.is_false(diffview_integration.goto_file("b/target.lua", 5, "headsha", 100))
  end)

  a.it("waits for M._attached before switching, not just for a matching window", function()
    make_target_window(10)
    diffview_integration._get_lib = function()
      return {
        get_current_view = function()
          return { set_file_by_path = function() end }
        end,
      }
    end
    diffview_integration._resolve_file = function(b)
      if b ~= bufnr then
        return nil
      end
      return { path = "b/target.lua", rev = { type = "COMMIT", commit = "headsha" } }
    end
    -- Not attached yet; attach a bit later, simulating _on_diff_buf's async flow.
    vim.defer_fn(function()
      diffview_integration._attached[bufnr] = true
    end, 50)

    local ok = diffview_integration.goto_file("b/target.lua", 5, "headsha", 1000)

    assert.is_true(ok)
    assert.equals(winid, vim.api.nvim_get_current_win())
  end)
end)
