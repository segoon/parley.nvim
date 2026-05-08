--- tests/parley/signs_spec.lua — Gutter signs + virtual text (Step 11)
---
--- All tests are synchronous: no I/O, no async. The Neovim API (extmarks,
--- namespaces) is fully available in the headless test environment.
---
--- Strategy:
---   • Create a scratch buffer per test (torn down by garbage collection).
---   • Call signs.render / signs.clear.
---   • Inspect results with nvim_buf_get_extmarks(…, {details = true}).

local signs = require("parley.signs")
local model = require("parley.model")

local saved = {}

local function save_seams()
  saved.now = signs._now
  saved.date = signs._date
  saved.strptime = signs._strptime
  saved.utc_offset = signs._utc_offset
end

local function restore_seams()
  signs._now = saved.now
  signs._date = saved.date
  signs._strptime = saved.strptime
  signs._utc_offset = saved.utc_offset
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Create a scratch buffer with `n` empty lines (extmarks need valid rows).
--- @param n integer
--- @return integer  bufnr
local function scratch(n)
  local bufnr = vim.api.nvim_create_buf(false, true)
  local lines = {}
  for _ = 1, n do
    lines[#lines + 1] = ""
  end
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return bufnr
end

--- Return all extmarks in `bufnr` with full details.
--- @param bufnr integer
--- @return table[]
local function all_extmarks(bufnr)
  local ns = signs._get_ns()
  return vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
end

--- Build a minimal Discussion.
--- @param id string
--- @param file string
--- @param line integer
--- @param first_comment_text string
--- @return parley.Discussion
local function make_discussion(id, file, line, first_comment_text)
  return model.new_discussion({
    id = id,
    file = file,
    line = line,
    comments = {
      model.new_comment({
        id = "c-" .. id,
        author = "alice",
        body = model.new_body({ text = first_comment_text, format = "plaintext" }),
        created_at = "2024-01-01T00:00:00Z",
        updated_at = "2024-01-01T00:00:00Z",
      }),
    },
  })
end

--- Build a non-stale Mapping.
--- @param local_line integer|nil
--- @param stale boolean|nil
--- @return parley.anchor.Mapping
local function make_mapping(local_line, stale)
  return {
    local_line = local_line,
    confidence = (stale and 0.0) or 1.0,
    stale = stale or false,
  }
end

--- Default opts that enable both signs and virtual text.
local function default_opts()
  return {
    signs = { enabled = true, text = "▐" },
    virtual_text = { enabled = true, max_width = 60 },
  }
end

-- ---------------------------------------------------------------------------
-- _truncate
-- ---------------------------------------------------------------------------

describe("signs._truncate", function()
  it("returns short text unchanged", function()
    assert.equal("hello", signs._truncate("hello", 60))
  end)

  it("returns text unchanged when length equals max_width", function()
    local s = ("x"):rep(60)
    assert.equal(s, signs._truncate(s, 60))
  end)

  it("truncates long text and appends ellipsis", function()
    local s = ("a"):rep(70)
    local result = signs._truncate(s, 60)
    -- Result must be (max_width-1) plain bytes + "…" (3 UTF-8 bytes) = 62 bytes.
    assert.equal(59 + 3, #result) -- 59 'a' bytes + 3-byte "…"
    assert.equal("…", result:sub(-3))
  end)

  it("handles max_width of 1 (edge case)", function()
    local result = signs._truncate("hello", 1)
    assert.equal("…", result)
  end)
end)

-- ---------------------------------------------------------------------------
-- clear
-- ---------------------------------------------------------------------------

describe("signs.clear", function()
  it("removes all extmarks placed by render", function()
    local bufnr = scratch(5)
    local disc = make_discussion("d1", "foo.lua", 2, "a comment")
    local mappings = { ["d1"] = make_mapping(2) }

    signs.render(bufnr, { disc }, mappings, default_opts())
    assert.is_true(#all_extmarks(bufnr) > 0)

    signs.clear(bufnr)
    assert.equal(0, #all_extmarks(bufnr))
  end)

  it("is a no-op on a buffer with no extmarks", function()
    local bufnr = scratch(3)
    assert.has_no_error(function()
      signs.clear(bufnr)
    end)
    assert.equal(0, #all_extmarks(bufnr))
  end)
end)

-- ---------------------------------------------------------------------------
-- render — basic placement
-- ---------------------------------------------------------------------------

describe("signs.render", function()
  before_each(function()
    save_seams()
    signs._now = function()
      return 160
    end
    signs._strptime = function(_fmt, value)
      local epochs = {
        ["2024-01-01T00:00:00Z"] = 100,
        ["2024-01-01T00:00:01Z"] = 101,
        ["2024-01-01T00:00:02Z"] = 102,
      }
      return epochs[value]
    end
    signs._date = function(fmt, epoch)
      if fmt == "%Y-%m-%d %H:%M:%S (%Z)" then
        local values = {
          [100] = "2026-05-08 15:08:38 (MSK)",
          [101] = "2026-05-08 15:08:39 (MSK)",
          [102] = "2026-05-08 15:08:40 (MSK)",
        }
        return values[epoch]
      end
      error("unexpected date format in test: " .. tostring(fmt))
    end
    signs._utc_offset = function(_epoch)
      return 0
    end
  end)

  after_each(function()
    restore_seams()
  end)

  it("places no extmarks when discussions list is empty", function()
    local bufnr = scratch(5)
    signs.render(bufnr, {}, {}, default_opts())
    assert.equal(0, #all_extmarks(bufnr))
  end)

  it("skips discussions whose mapping has local_line = nil", function()
    local bufnr = scratch(5)
    local disc = make_discussion("d1", "foo.lua", 2, "deleted line comment")
    local mappings = { ["d1"] = make_mapping(nil, true) }

    signs.render(bufnr, { disc }, mappings, default_opts())
    assert.equal(0, #all_extmarks(bufnr))
  end)

  it("skips discussions with no mapping entry", function()
    local bufnr = scratch(5)
    local disc = make_discussion("d1", "foo.lua", 2, "orphan")
    -- Empty mappings table — no entry for d1.
    signs.render(bufnr, { disc }, {}, default_opts())
    assert.equal(0, #all_extmarks(bufnr))
  end)

  it("places one extmark per discussion with a valid local_line", function()
    local bufnr = scratch(10)
    local d1 = make_discussion("d1", "foo.lua", 3, "comment one")
    local d2 = make_discussion("d2", "foo.lua", 7, "comment two")
    local mappings = {
      ["d1"] = make_mapping(3),
      ["d2"] = make_mapping(7),
    }

    signs.render(bufnr, { d1, d2 }, mappings, default_opts())
    assert.equal(2, #all_extmarks(bufnr))
  end)

  it("places extmark at the correct 0-indexed row", function()
    local bufnr = scratch(10)
    local disc = make_discussion("d1", "foo.lua", 5, "hi")
    local mappings = { ["d1"] = make_mapping(5) }

    signs.render(bufnr, { disc }, mappings, default_opts())
    local marks = all_extmarks(bufnr)
    assert.equal(1, #marks)
    -- marks[i] = { id, row, col, details }
    assert.equal(4, marks[1][2]) -- row is 0-indexed: line 5 → row 4
    assert.equal(0, marks[1][3]) -- col is always 0
  end)

  -- -------------------------------------------------------------------------
  -- Sign column
  -- -------------------------------------------------------------------------

  it("includes sign_text from opts when signs.enabled = true", function()
    local bufnr = scratch(5)
    local disc = make_discussion("d1", "foo.lua", 2, "hi")
    local mappings = { ["d1"] = make_mapping(2) }
    local opts = default_opts()
    opts.signs.text = "●"

    signs.render(bufnr, { disc }, mappings, opts)
    local marks = all_extmarks(bufnr)
    assert.equal(1, #marks)
    -- Neovim normalises sign_text to exactly 2 screen cells; trim trailing
    -- whitespace before comparing to the configured character.
    assert.equal("●", marks[1][4].sign_text:match("^(.-)%s*$"))
  end)

  it("omits sign_text when signs.enabled = false", function()
    local bufnr = scratch(5)
    local disc = make_discussion("d1", "foo.lua", 2, "hi")
    local mappings = { ["d1"] = make_mapping(2) }
    local opts = default_opts()
    opts.signs.enabled = false

    signs.render(bufnr, { disc }, mappings, opts)
    local marks = all_extmarks(bufnr)
    assert.equal(1, #marks) -- extmark still placed
    assert.is_nil(marks[1][4].sign_text)
  end)

  -- -------------------------------------------------------------------------
  -- Virtual text
  -- -------------------------------------------------------------------------

  it("renders metadata and first-comment snippet in below-line virtual lines", function()
    local bufnr = scratch(5)
    local disc = make_discussion("d1", "foo.lua", 2, "check the nil guard here")
    local mappings = { ["d1"] = make_mapping(2) }

    signs.render(bufnr, { disc }, mappings, default_opts())
    local marks = all_extmarks(bufnr)
    assert.equal(1, #marks)
    local virt_lines = marks[1][4].virt_lines
    assert.is_not_nil(virt_lines)
    assert.is_true(#virt_lines > 0)
    assert.equals("alice · 2026-05-08 15:08:38 (MSK) (1 min ago)", virt_lines[1][1][1])
    assert.equals("check the nil guard here", virt_lines[2][1][1])
  end)

  it("truncates long comment text in virtual lines", function()
    local bufnr = scratch(5)
    local long_text = ("x"):rep(120)
    local disc = make_discussion("d1", "foo.lua", 2, long_text)
    local mappings = { ["d1"] = make_mapping(2) }
    local opts = default_opts()
    opts.virtual_text.max_width = 60

    signs.render(bufnr, { disc }, mappings, opts)
    local marks = all_extmarks(bufnr)
    local virt_lines = marks[1][4].virt_lines
    assert.equal("…", virt_lines[2][1][1]:sub(-3))
  end)

  it("renders multiline comments as multiple virtual lines", function()
    local bufnr = scratch(5)
    local disc = make_discussion("d1", "foo.lua", 2, "line one\nline two\nline three")
    local mappings = { ["d1"] = make_mapping(2) }

    signs.render(bufnr, { disc }, mappings, default_opts())
    local virt_lines = all_extmarks(bufnr)[1][4].virt_lines

    assert.equals(4, #virt_lines)
    assert.equals("alice · 2026-05-08 15:08:38 (MSK) (1 min ago)", virt_lines[1][1][1])
    assert.equals("line one", virt_lines[2][1][1])
    assert.equals("line two", virt_lines[3][1][1])
    assert.equals("line three", virt_lines[4][1][1])
  end)

  it("adds a summary virtual line when the discussion has additional comments", function()
    local bufnr = scratch(5)
    local disc = model.new_discussion({
      id = "d1",
      file = "foo.lua",
      line = 2,
      comments = {
        model.new_comment({
          id = "c1",
          author = "alice",
          body = model.new_body({ text = "first", format = "plaintext" }),
          created_at = "2024-01-01T00:00:00Z",
          updated_at = "2024-01-01T00:00:00Z",
        }),
        model.new_comment({
          id = "c2",
          author = "bob",
          body = model.new_body({ text = "second", format = "plaintext" }),
          created_at = "2024-01-01T00:00:01Z",
          updated_at = "2024-01-01T00:00:01Z",
          parent_comment_id = "c1",
        }),
        model.new_comment({
          id = "c3",
          author = "carol",
          body = model.new_body({ text = "third", format = "plaintext" }),
          created_at = "2024-01-01T00:00:02Z",
          updated_at = "2024-01-01T00:00:02Z",
          parent_comment_id = "c1",
        }),
      },
    })
    local mappings = { ["d1"] = make_mapping(2) }

    signs.render(bufnr, { disc }, mappings, default_opts())
    local marks = all_extmarks(bufnr)
    local virt_lines = marks[1][4].virt_lines

    assert.equals(3, #virt_lines)
    assert.equals("alice · 2026-05-08 15:08:38 (MSK) (1 min ago)", virt_lines[1][1][1])
    assert.equals("first", virt_lines[2][1][1])
    assert.equals("(2 more comments)", virt_lines[3][1][1])
  end)

  it("omits virt_text when virtual_text.enabled = false", function()
    local bufnr = scratch(5)
    local disc = make_discussion("d1", "foo.lua", 2, "hi")
    local mappings = { ["d1"] = make_mapping(2) }
    local opts = default_opts()
    opts.virtual_text.enabled = false

    signs.render(bufnr, { disc }, mappings, opts)
    local marks = all_extmarks(bufnr)
    assert.equal(1, #marks) -- extmark still placed
    local virt_lines = marks[1][4].virt_lines
    assert.is_true(virt_lines == nil or #virt_lines == 0)
  end)

  -- -------------------------------------------------------------------------
  -- Stale mappings
  -- -------------------------------------------------------------------------

  it("uses stale highlight groups for stale mappings", function()
    local bufnr = scratch(5)
    local disc = make_discussion("d1", "foo.lua", 2, "stale comment")
    local mappings = { ["d1"] = make_mapping(2, true) }

    signs.render(bufnr, { disc }, mappings, default_opts())
    local marks = all_extmarks(bufnr)
    assert.equal(1, #marks)
    local det = marks[1][4]
    assert.equal("ParleyStaleSign", det.sign_hl_group)
    local virt_lines = det.virt_lines
    assert.is_not_nil(virt_lines)
    assert.equal("ParleyStaleVirtualTextMeta", virt_lines[1][1][2])
    assert.equal("ParleyStaleVirtualText", virt_lines[2][1][2])
  end)

  it("uses normal highlight groups for non-stale mappings", function()
    local bufnr = scratch(5)
    local disc = make_discussion("d1", "foo.lua", 2, "fresh comment")
    local mappings = { ["d1"] = make_mapping(2, false) }

    signs.render(bufnr, { disc }, mappings, default_opts())
    local marks = all_extmarks(bufnr)
    local det = marks[1][4]
    assert.equal("ParleySign", det.sign_hl_group)
    local virt_lines = det.virt_lines
    assert.equal("ParleyVirtualTextMeta", virt_lines[1][1][2])
    assert.equal("ParleyVirtualText", virt_lines[2][1][2])
  end)

  -- -------------------------------------------------------------------------
  -- Both disabled
  -- -------------------------------------------------------------------------

  it("still places an extmark when both signs and virtual_text are disabled", function()
    local bufnr = scratch(5)
    local disc = make_discussion("d1", "foo.lua", 2, "hi")
    local mappings = { ["d1"] = make_mapping(2) }
    local opts = {
      signs = { enabled = false, text = "▐" },
      virtual_text = { enabled = false, max_width = 60 },
    }

    signs.render(bufnr, { disc }, mappings, opts)
    -- Extmark placed for future navigation (Step 12)
    assert.equal(1, #all_extmarks(bufnr))
  end)

  -- -------------------------------------------------------------------------
  -- Multiple discussions on the same line
  -- -------------------------------------------------------------------------

  it("places one extmark per discussion even when they share a line", function()
    local bufnr = scratch(5)
    local d1 = make_discussion("d1", "foo.lua", 3, "first")
    local d2 = make_discussion("d2", "foo.lua", 3, "second")
    local mappings = {
      ["d1"] = make_mapping(3),
      ["d2"] = make_mapping(3),
    }

    signs.render(bufnr, { d1, d2 }, mappings, default_opts())
    local marks = all_extmarks(bufnr)
    assert.equal(2, #marks)
    assert.equal(2, marks[1][2]) -- row 2 (0-indexed line 3)
    assert.equal(2, marks[2][2])
  end)

  -- -------------------------------------------------------------------------
  -- Idempotency
  -- -------------------------------------------------------------------------

  it("does not duplicate extmarks when render is called twice", function()
    local bufnr = scratch(5)
    local disc = make_discussion("d1", "foo.lua", 2, "hi")
    local mappings = { ["d1"] = make_mapping(2) }

    signs.render(bufnr, { disc }, mappings, default_opts())
    signs.render(bufnr, { disc }, mappings, default_opts())
    assert.equal(1, #all_extmarks(bufnr))
  end)

  -- -------------------------------------------------------------------------
  -- Comment with no body text (edge case)
  -- -------------------------------------------------------------------------

  it("handles empty first-comment text gracefully", function()
    local bufnr = scratch(5)
    local disc = make_discussion("d1", "foo.lua", 2, "")
    local mappings = { ["d1"] = make_mapping(2) }

    assert.has_no_error(function()
      signs.render(bufnr, { disc }, mappings, default_opts())
    end)
    assert.equal(1, #all_extmarks(bufnr))
  end)

  -- -------------------------------------------------------------------------
  -- Discussion with no comments (edge case)
  -- -------------------------------------------------------------------------

  it("handles discussion with zero comments gracefully", function()
    local bufnr = scratch(5)
    local disc = model.new_discussion({
      id = "d1",
      file = "foo.lua",
      line = 2,
      comments = {},
    })
    local mappings = { ["d1"] = make_mapping(2) }

    assert.has_no_error(function()
      signs.render(bufnr, { disc }, mappings, default_opts())
    end)
    -- Extmark still placed; virt_lines may be empty but no crash
    assert.equal(1, #all_extmarks(bufnr))
  end)
end)
