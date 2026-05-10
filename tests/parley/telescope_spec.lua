--- tests/parley/telescope_spec.lua — Telescope integration.

local model = require("parley.model")

--- @param id string
--- @param file string
--- @param line integer
--- @param text string
--- @return parley.Discussion
local function make_discussion(id, file, line, text)
  return model.new_discussion({
    id = id,
    file = file,
    line = line,
    resolved = false,
    comments = {
      model.new_comment({
        id = id .. "-c1",
        author = "alice",
        body = model.new_body({ text = text, format = "markdown" }),
        created_at = "2024-01-01T10:00:00Z",
        updated_at = "2024-01-01T10:00:00Z",
      }),
    },
  })
end

describe("parley Telescope integration", function()
  local saved = {}

  before_each(function()
    saved.parley_telescope = package.loaded["parley.telescope"]
    saved.parley_read = package.loaded["parley.services.read"]
    saved.parley_discussion_window = package.loaded["parley.discussion_window"]
    saved.telescope = package.loaded["telescope"]
    saved.telescope_pickers = package.loaded["telescope.pickers"]
    saved.telescope_finders = package.loaded["telescope.finders"]
    saved.telescope_config = package.loaded["telescope.config"]
    saved.telescope_actions = package.loaded["telescope.actions"]
    saved.telescope_action_state = package.loaded["telescope.actions.state"]
    saved.parley_discussions_ext = package.loaded["telescope._extensions.parley_discussions"]
    saved.parley_discussions_file_ext = package.loaded["telescope._extensions.parley_discussions_file"]

    package.loaded["parley.telescope"] = nil
    package.loaded["telescope._extensions.parley_discussions"] = nil
    package.loaded["telescope._extensions.parley_discussions_file"] = nil
  end)

  after_each(function()
    package.loaded["parley.telescope"] = saved.parley_telescope
    package.loaded["parley.services.read"] = saved.parley_read
    package.loaded["parley.discussion_window"] = saved.parley_discussion_window
    package.loaded["telescope"] = saved.telescope
    package.loaded["telescope.pickers"] = saved.telescope_pickers
    package.loaded["telescope.finders"] = saved.telescope_finders
    package.loaded["telescope.config"] = saved.telescope_config
    package.loaded["telescope.actions"] = saved.telescope_actions
    package.loaded["telescope.actions.state"] = saved.telescope_action_state
    package.loaded["telescope._extensions.parley_discussions"] = saved.parley_discussions_ext
    package.loaded["telescope._extensions.parley_discussions_file"] = saved.parley_discussions_file_ext
  end)

  it("builds all-discussion and current-file pickers", function()
    local captured = {}

    package.loaded["parley.services.read"] = {
      get_buffer_state = function(_bufnr)
        return {
          pr = { id = "42", title = "Add feature" },
          vcs_info = { root = "/repo" },
          rel_path = "src/foo.lua",
        }
      end,
      list_discussions = function(_bufnr, opts)
        if opts and opts.scope == "all" then
          return {
            make_discussion("d1", "src/foo.lua", 10, "foo"),
            make_discussion("d2", "src/bar.lua", 20, "bar"),
          }
        end
        return { make_discussion("d1", "src/foo.lua", 10, "foo") }
      end,
      refresh_async = function(_bufnr, _opts, callback)
        if callback then
          callback({})
        end
      end,
    }
    package.loaded["parley.discussion_window"] = { open_discussion = function() end }
    package.loaded["telescope.finders"] = {
      new_table = function(spec)
        captured.finder = spec
        return spec
      end,
    }
    package.loaded["telescope.config"] = {
      values = {
        generic_sorter = function(_opts)
          return "sorter"
        end,
      },
    }
    package.loaded["telescope.actions"] = {
      close = function() end,
      select_default = {
        replace = function(_, _fn) end,
      },
    }
    package.loaded["telescope.actions.state"] = { get_selected_entry = function() end }
    package.loaded["telescope.pickers"] = {
      new = function(opts, spec)
        captured.opts = opts
        captured.spec = spec
        return {
          find = function()
            captured.found = true
          end,
        }
      end,
    }

    local telescope_integration = require("parley.telescope")

    telescope_integration.discussions()
    assert.is_true(captured.found)
    assert.equals(2, #captured.finder.results)
    assert.equals("Parley Discussions", captured.spec.prompt_title)

    telescope_integration.discussions_file()
    assert.equals(1, #captured.finder.results)
    assert.equals("Parley Discussions (File)", captured.spec.prompt_title)
  end)

  --- Build the harness shared by every cursor-jump scenario.
  --- @param refresh_snapshot table|nil  Snapshot value passed to refresh_async's callback
  --- @param target_lines integer        Line count for the buffer M._edit creates
  --- @return table  { run, edits, cursors, refreshed, opened, telescope_integration }
  local function setup_jump_harness(refresh_snapshot, target_lines)
    local selected_entry
    local select_default
    local edits = {}
    local cursors = {}
    local refreshed = {}
    local opened = {}

    package.loaded["parley.services.read"] = {
      get_buffer_state = function(_bufnr)
        return {
          pr = { id = "42", title = "Add feature" },
          vcs_info = { root = "/repo" },
          rel_path = "src/foo.lua",
        }
      end,
      list_discussions = function()
        return { make_discussion("d2", "src/bar.lua", 20, "bar") }
      end,
      refresh_async = function(bufnr, opts, callback)
        refreshed[#refreshed + 1] = { bufnr = bufnr, opts = opts }
        if callback then
          callback(refresh_snapshot)
        end
      end,
    }
    package.loaded["parley.discussion_window"] = {
      open_discussion = function(bufnr, discussion_id)
        opened[#opened + 1] = { bufnr = bufnr, discussion_id = discussion_id }
      end,
    }
    package.loaded["telescope.finders"] = {
      new_table = function(spec)
        return spec
      end,
    }
    package.loaded["telescope.config"] = {
      values = {
        generic_sorter = function(_opts)
          return "sorter"
        end,
      },
    }
    package.loaded["telescope.actions"] = {
      close = function(_prompt_bufnr) end,
      select_default = {
        replace = function(_, fn)
          select_default = fn
        end,
      },
    }
    package.loaded["telescope.actions.state"] = {
      get_selected_entry = function()
        return selected_entry
      end,
    }
    package.loaded["telescope.pickers"] = {
      new = function(_opts, spec)
        return {
          find = function()
            spec.attach_mappings(91)
          end,
        }
      end,
    }

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    local telescope_integration = require("parley.telescope")
    telescope_integration._edit = function(path)
      edits[#edits + 1] = path
      local target = vim.api.nvim_create_buf(false, true)
      local filler = {}
      for i = 1, target_lines do
        filler[i] = "line " .. i
      end
      vim.api.nvim_buf_set_lines(target, 0, -1, false, filler)
      vim.api.nvim_set_current_buf(target)
    end
    telescope_integration._set_cursor = function(line)
      cursors[#cursors + 1] = line
    end

    return {
      run = function()
        telescope_integration.discussions()
        selected_entry = {
          value = {
            discussion = make_discussion("d2", "src/bar.lua", 20, "bar"),
            path = "/repo/src/bar.lua",
          },
        }
        select_default()
      end,
      edits = edits,
      cursors = cursors,
      refreshed = refreshed,
      opened = opened,
    }
  end

  it("jumps to the mapped local line and opens the float", function()
    local h = setup_jump_harness({
      mappings = {
        d2 = { local_line = 5, stale = false, confidence = 1.0 },
      },
    }, 30)

    h.run()

    assert.same({ "/repo/src/bar.lua" }, h.edits)
    assert.same({ 5 }, h.cursors)
    assert.equals(1, #h.refreshed)
    assert.same({ force = true, notify_errors = true }, h.refreshed[1].opts)
    assert.equals("d2", h.opened[1].discussion_id)
  end)

  it("opens the float without moving the cursor when the anchor was deleted locally", function()
    local h = setup_jump_harness({
      mappings = {
        d2 = { local_line = nil, stale = true, confidence = 0.0 },
      },
    }, 30)

    h.run()

    assert.same({}, h.cursors)
    assert.equals("d2", h.opened[1].discussion_id)
  end)

  it("opens the float without moving the cursor when no mapping is available", function()
    local h = setup_jump_harness({}, 30)

    h.run()

    assert.same({}, h.cursors)
    assert.equals("d2", h.opened[1].discussion_id)
  end)

  it("clamps the cursor to the buffer's last line when the mapping exceeds it", function()
    local h = setup_jump_harness({
      mappings = {
        d2 = { local_line = 999, stale = false, confidence = 1.0 },
      },
    }, 8)

    h.run()

    assert.same({ 8 }, h.cursors)
    assert.equals("d2", h.opened[1].discussion_id)
  end)

  it("registers Telescope extension shims for both picker names", function()
    package.loaded["parley.telescope"] = {
      discussions = function()
        return "all"
      end,
      discussions_file = function()
        return "file"
      end,
    }
    package.loaded["telescope"] = {
      register_extension = function(spec)
        return spec
      end,
    }

    local all_extension = require("telescope._extensions.parley_discussions")
    local file_extension = require("telescope._extensions.parley_discussions_file")

    assert.equals("all", all_extension.exports.parley_discussions())
    assert.equals("file", file_extension.exports.parley_discussions_file())
  end)
end)
