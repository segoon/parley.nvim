--- Tests for parley.buffer_context — Buffer context detection.
--- Run via: make test

local a = require("plenary.async").tests
local buffer_context = require("parley.buffer_context")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Build a mock _get_buf_props that returns fixed properties.
---
--- @param props { filetype?: string, name?: string, buftype?: string }
--- @return fun(bufnr: integer): { filetype: string, name: string, buftype: string }
local function make_props(props)
  return function(_bufnr)
    return {
      filetype = props.filetype or "",
      name = props.name or "",
      buftype = props.buftype or "",
    }
  end
end

--- Build a mock _vcs_detect that returns a fixed VcsInfo (or nil).
---
--- @param vcs_info parley.VcsInfo|nil
--- @return fun(path: string): parley.VcsInfo|nil
local function make_vcs_detect(vcs_info)
  return function(_path)
    return vcs_info
  end
end

--- Sample VcsInfo used throughout the suite.
--- @type parley.VcsInfo
local SAMPLE_VCS = {
  vcs = "git",
  root = "/repo",
  branch = "main",
  remote_url = "https://github.com/org/repo.git",
}

-- ---------------------------------------------------------------------------
-- Test state
-- ---------------------------------------------------------------------------

local orig_get_buf_props
local orig_vcs_detect

-- ---------------------------------------------------------------------------
-- Suite
-- ---------------------------------------------------------------------------

a.describe("parley.buffer_context classify", function()
  a.before_each(function()
    orig_get_buf_props = buffer_context._get_buf_props
    orig_vcs_detect = buffer_context._vcs_detect
  end)

  a.after_each(function()
    buffer_context._get_buf_props = orig_get_buf_props
    buffer_context._vcs_detect = orig_vcs_detect
  end)

  -- -------------------------------------------------------------------------
  -- diffview detection — filetypes
  -- -------------------------------------------------------------------------

  local diffview_filetypes = {
    "DiffviewFiles",
    "DiffviewDiff",
    "DiffviewDiffFiles",
    "DiffviewFileHistory",
    "DiffviewFileHistoryPanel",
  }

  for _, ft in ipairs(diffview_filetypes) do
    local ft_capture = ft
    a.it("kind is 'diffview' for filetype " .. ft_capture, function()
      buffer_context._get_buf_props = make_props({ filetype = ft_capture, name = "/some/file" })
      buffer_context._vcs_detect = make_vcs_detect(SAMPLE_VCS)

      local ctx = buffer_context.classify(1)

      assert.equals("diffview", ctx.kind)
    end)
  end

  -- -------------------------------------------------------------------------
  -- diffview detection — buffer name prefix
  -- -------------------------------------------------------------------------

  a.it("kind is 'diffview' for name starting with 'diffview://'", function()
    buffer_context._get_buf_props = make_props({ filetype = "", name = "diffview://something" })
    buffer_context._vcs_detect = make_vcs_detect(nil)

    local ctx = buffer_context.classify(1)

    assert.equals("diffview", ctx.kind)
  end)

  a.it("kind is 'diffview' for diffview:// name even when buftype is non-empty", function()
    buffer_context._get_buf_props = make_props({ filetype = "", name = "diffview://something", buftype = "nofile" })
    buffer_context._vcs_detect = make_vcs_detect(nil)

    local ctx = buffer_context.classify(1)

    assert.equals("diffview", ctx.kind)
  end)

  a.it("kind is 'diffview' for DiffviewFiles filetype even when buftype is non-empty", function()
    buffer_context._get_buf_props = make_props({ filetype = "DiffviewFiles", name = "", buftype = "nofile" })
    buffer_context._vcs_detect = make_vcs_detect(nil)

    local ctx = buffer_context.classify(1)

    assert.equals("diffview", ctx.kind)
  end)

  -- -------------------------------------------------------------------------
  -- diffview — field values
  -- -------------------------------------------------------------------------

  a.it("path is nil for diffview buffers", function()
    buffer_context._get_buf_props = make_props({ filetype = "DiffviewFiles" })
    buffer_context._vcs_detect = make_vcs_detect(nil)

    local ctx = buffer_context.classify(1)

    assert.is_nil(ctx.path)
  end)

  a.it("vcs_info is nil for diffview buffers", function()
    buffer_context._get_buf_props = make_props({ filetype = "DiffviewFiles" })
    buffer_context._vcs_detect = make_vcs_detect(SAMPLE_VCS)

    local ctx = buffer_context.classify(1)

    assert.is_nil(ctx.vcs_info)
  end)

  a.it("bufnr is preserved for diffview buffers", function()
    buffer_context._get_buf_props = make_props({ filetype = "DiffviewFiles" })
    buffer_context._vcs_detect = make_vcs_detect(nil)

    local ctx = buffer_context.classify(42)

    assert.equals(42, ctx.bufnr)
  end)

  -- -------------------------------------------------------------------------
  -- diffview — _vcs_detect is not called
  -- -------------------------------------------------------------------------

  a.it("_vcs_detect is not called for diffview filetype buffers", function()
    local called = false
    buffer_context._get_buf_props = make_props({ filetype = "DiffviewFiles", name = "" })
    buffer_context._vcs_detect = function(_path)
      called = true
      return nil
    end

    buffer_context.classify(1)

    assert.is_false(called)
  end)

  a.it("_vcs_detect is not called for diffview:// name buffers", function()
    local called = false
    buffer_context._get_buf_props = make_props({ filetype = "", name = "diffview://panel" })
    buffer_context._vcs_detect = function(_path)
      called = true
      return nil
    end

    buffer_context.classify(1)

    assert.is_false(called)
  end)

  -- -------------------------------------------------------------------------
  -- non-VCS: special buftypes
  -- -------------------------------------------------------------------------

  a.it("kind is 'non_vcs' for buftype 'terminal'", function()
    buffer_context._get_buf_props = make_props({ buftype = "terminal", name = "/some/file" })
    buffer_context._vcs_detect = make_vcs_detect(SAMPLE_VCS)

    local ctx = buffer_context.classify(1)

    assert.equals("non_vcs", ctx.kind)
  end)

  a.it("kind is 'non_vcs' for buftype 'nofile'", function()
    buffer_context._get_buf_props = make_props({ buftype = "nofile", name = "/some/file" })
    buffer_context._vcs_detect = make_vcs_detect(SAMPLE_VCS)

    local ctx = buffer_context.classify(1)

    assert.equals("non_vcs", ctx.kind)
  end)

  a.it("kind is 'non_vcs' for buftype 'prompt'", function()
    buffer_context._get_buf_props = make_props({ buftype = "prompt", name = "/some/file" })
    buffer_context._vcs_detect = make_vcs_detect(SAMPLE_VCS)

    local ctx = buffer_context.classify(1)

    assert.equals("non_vcs", ctx.kind)
  end)

  a.it("kind is 'non_vcs' for buftype 'quickfix'", function()
    buffer_context._get_buf_props = make_props({ buftype = "quickfix", name = "/some/file" })
    buffer_context._vcs_detect = make_vcs_detect(SAMPLE_VCS)

    local ctx = buffer_context.classify(1)

    assert.equals("non_vcs", ctx.kind)
  end)

  a.it("_vcs_detect is not called for special-buftype buffers", function()
    local called = false
    buffer_context._get_buf_props = make_props({ buftype = "terminal", name = "/some/path" })
    buffer_context._vcs_detect = function(_path)
      called = true
      return nil
    end

    buffer_context.classify(1)

    assert.is_false(called)
  end)

  a.it("path is nil for special-buftype buffers", function()
    buffer_context._get_buf_props = make_props({ buftype = "nofile", name = "/some/file" })
    buffer_context._vcs_detect = make_vcs_detect(nil)

    local ctx = buffer_context.classify(1)

    assert.is_nil(ctx.path)
  end)

  a.it("vcs_info is nil for special-buftype buffers", function()
    buffer_context._get_buf_props = make_props({ buftype = "terminal", name = "/some/file" })
    buffer_context._vcs_detect = make_vcs_detect(SAMPLE_VCS)

    local ctx = buffer_context.classify(1)

    assert.is_nil(ctx.vcs_info)
  end)

  -- -------------------------------------------------------------------------
  -- non-VCS: empty name
  -- -------------------------------------------------------------------------

  a.it("kind is 'non_vcs' for buffer with empty name and empty buftype", function()
    buffer_context._get_buf_props = make_props({ filetype = "lua", name = "", buftype = "" })
    buffer_context._vcs_detect = make_vcs_detect(SAMPLE_VCS)

    local ctx = buffer_context.classify(1)

    assert.equals("non_vcs", ctx.kind)
  end)

  a.it("path is nil for buffer with empty name", function()
    buffer_context._get_buf_props = make_props({ filetype = "lua", name = "", buftype = "" })
    buffer_context._vcs_detect = make_vcs_detect(SAMPLE_VCS)

    local ctx = buffer_context.classify(1)

    assert.is_nil(ctx.path)
  end)

  -- -------------------------------------------------------------------------
  -- non-VCS: VCS detection fails
  -- -------------------------------------------------------------------------

  a.it("kind is 'non_vcs' when _vcs_detect returns nil", function()
    buffer_context._get_buf_props = make_props({ filetype = "lua", name = "/some/file.lua", buftype = "" })
    buffer_context._vcs_detect = make_vcs_detect(nil)

    local ctx = buffer_context.classify(1)

    assert.equals("non_vcs", ctx.kind)
  end)

  a.it("path is the buffer name even when _vcs_detect returns nil", function()
    buffer_context._get_buf_props = make_props({ filetype = "lua", name = "/some/file.lua", buftype = "" })
    buffer_context._vcs_detect = make_vcs_detect(nil)

    local ctx = buffer_context.classify(1)

    assert.equals("/some/file.lua", ctx.path)
  end)

  a.it("vcs_info is nil when _vcs_detect returns nil", function()
    buffer_context._get_buf_props = make_props({ filetype = "lua", name = "/some/file.lua", buftype = "" })
    buffer_context._vcs_detect = make_vcs_detect(nil)

    local ctx = buffer_context.classify(1)

    assert.is_nil(ctx.vcs_info)
  end)

  -- -------------------------------------------------------------------------
  -- regular: successful VCS detection
  -- -------------------------------------------------------------------------

  a.it("kind is 'regular' when _vcs_detect succeeds", function()
    buffer_context._get_buf_props = make_props({ filetype = "lua", name = "/repo/src/foo.lua", buftype = "" })
    buffer_context._vcs_detect = make_vcs_detect(SAMPLE_VCS)

    local ctx = buffer_context.classify(1)

    assert.equals("regular", ctx.kind)
  end)

  a.it("path equals buffer name for regular buffers", function()
    buffer_context._get_buf_props = make_props({ filetype = "lua", name = "/repo/src/foo.lua", buftype = "" })
    buffer_context._vcs_detect = make_vcs_detect(SAMPLE_VCS)

    local ctx = buffer_context.classify(1)

    assert.equals("/repo/src/foo.lua", ctx.path)
  end)

  a.it("vcs_info is populated with what _vcs_detect returned", function()
    buffer_context._get_buf_props = make_props({ filetype = "lua", name = "/repo/src/foo.lua", buftype = "" })
    buffer_context._vcs_detect = make_vcs_detect(SAMPLE_VCS)

    local ctx = buffer_context.classify(1)

    assert.same(SAMPLE_VCS, ctx.vcs_info)
  end)

  a.it("bufnr is preserved for regular buffers", function()
    buffer_context._get_buf_props = make_props({ filetype = "lua", name = "/repo/src/foo.lua", buftype = "" })
    buffer_context._vcs_detect = make_vcs_detect(SAMPLE_VCS)

    local ctx = buffer_context.classify(7)

    assert.equals(7, ctx.bufnr)
  end)

  -- -------------------------------------------------------------------------
  -- Seam: _get_buf_props receives the correct bufnr
  -- -------------------------------------------------------------------------

  a.it("_get_buf_props is called with the bufnr passed to classify", function()
    local received_bufnr = nil
    buffer_context._get_buf_props = function(bufnr)
      received_bufnr = bufnr
      return { filetype = "", name = "", buftype = "" }
    end
    buffer_context._vcs_detect = make_vcs_detect(nil)

    buffer_context.classify(99)

    assert.equals(99, received_bufnr)
  end)

  -- -------------------------------------------------------------------------
  -- Seam: _vcs_detect receives the buffer name as path
  -- -------------------------------------------------------------------------

  a.it("_vcs_detect receives the buffer name as the path argument", function()
    local received_path = nil
    buffer_context._get_buf_props = make_props({ filetype = "lua", name = "/repo/file.lua", buftype = "" })
    buffer_context._vcs_detect = function(path)
      received_path = path
      return SAMPLE_VCS
    end

    buffer_context.classify(1)

    assert.equals("/repo/file.lua", received_path)
  end)

  -- -------------------------------------------------------------------------
  -- non-VCS: bufnr is preserved
  -- -------------------------------------------------------------------------

  a.it("bufnr is preserved for non_vcs buffers", function()
    buffer_context._get_buf_props = make_props({ filetype = "lua", name = "", buftype = "" })
    buffer_context._vcs_detect = make_vcs_detect(nil)

    local ctx = buffer_context.classify(55)

    assert.equals(55, ctx.bufnr)
  end)
end)
