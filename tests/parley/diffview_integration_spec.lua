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
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
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

  a.it("does nothing for a base/old-side diff buffer", function()
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
