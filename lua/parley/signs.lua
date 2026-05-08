--- parley.signs — Gutter signs and virtual text for commented lines.
---
--- Places Neovim extmarks on buffer lines that have PR discussion anchors.
--- Each extmark carries:
---   • a gutter sign (sign_text)         — configurable character, default "▐"
---   • virtual lines below the comment   — author/timestamp metadata plus body
---
--- Highlight groups (defined with default = true so users can override):
---   ParleySign                 → DiagnosticSignInfo         (normal sign)
---   ParleyStaleSign            → Comment                    (stale/diverged sign)
---   ParleyVirtualTextMeta      → DiagnosticVirtualTextHint  (normal metadata)
---   ParleyStaleVirtualTextMeta → Comment                    (stale metadata)
---   ParleyVirtualText          → DiagnosticVirtualTextInfo  (normal body)
---   ParleyStaleVirtualText     → Comment                    (stale body)
---
--- Usage:
---   local signs = require("parley.signs")
---   signs.setup_highlights()          -- call once from setup()
---   signs.render(bufnr, discussions, mappings, opts)
---   signs.clear(bufnr)

local model = require("parley.model")
local timestamp_format = require("parley.timestamp")

local M = {}

-- ---------------------------------------------------------------------------
-- Namespace
-- ---------------------------------------------------------------------------

--- Cached namespace id; lazily created on first access.
--- @type integer|nil
M._ns_id = nil

--- Return (creating if needed) the parley extmark namespace id.
--- @return integer
function M._get_ns()
  if not M._ns_id then
    M._ns_id = vim.api.nvim_create_namespace("parley")
  end
  return M._ns_id
end

-- ---------------------------------------------------------------------------
-- Highlight groups
-- ---------------------------------------------------------------------------

--- Highlight group names (single source of truth).
local HL_SIGN = "ParleySign"
local HL_STALE_SIGN = "ParleyStaleSign"
local HL_VTEXT_META = "ParleyVirtualTextMeta"
local HL_STALE_VTEXT_META = "ParleyStaleVirtualTextMeta"
local HL_VTEXT = "ParleyVirtualText"
local HL_STALE_VTEXT = "ParleyStaleVirtualText"

--- Define parley highlight groups, linking them to built-in groups.
---
--- Uses `default = true` so user-defined highlights take precedence.
--- Call once from setup().
function M.setup_highlights()
  vim.api.nvim_set_hl(0, HL_SIGN, { link = "DiagnosticSignInfo", default = true })
  vim.api.nvim_set_hl(0, HL_STALE_SIGN, { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, HL_VTEXT_META, { link = "DiagnosticVirtualTextHint", default = true })
  vim.api.nvim_set_hl(0, HL_STALE_VTEXT_META, { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, HL_VTEXT, { link = "DiagnosticVirtualTextInfo", default = true })
  vim.api.nvim_set_hl(0, HL_STALE_VTEXT, { link = "Comment", default = true })
end

--- @type fun(): integer
M._now = function()
  return os.time()
end

--- @type fun(fmt: string, time: integer): string
M._date = function(fmt, time)
  return os.date(fmt, time)
end

--- @type fun(fmt: string, value: string): integer|nil
M._strptime = function(fmt, value)
  return vim.fn.strptime(fmt, value)
end

-- ---------------------------------------------------------------------------
-- Pure helpers
-- ---------------------------------------------------------------------------

--- Truncate `text` to at most `max_width` characters.
---
--- If `text` is longer than `max_width`, it is cut to `max_width - 1`
--- characters and the Unicode ellipsis "…" (U+2026, 3 UTF-8 bytes) is
--- appended, giving a visual width of `max_width`.
---
--- @param text      string   Input text
--- @param max_width integer  Maximum number of characters
--- @return string
function M._truncate(text, max_width)
  if #text <= max_width then
    return text
  end
  -- Keep (max_width - 1) bytes then append the ellipsis.
  -- NOTE: this is byte-level truncation; multi-byte characters may be split.
  -- For the virtual-text use-case (ASCII-dominant comment snippets) this is
  -- acceptable and avoids pulling in a full Unicode library.
  if max_width <= 1 then
    return "…"
  end
  return text:sub(1, max_width - 1) .. "…"
end

---@param timestamp string
---@return string
local function format_comment_timestamp(timestamp)
  return timestamp_format.format(timestamp, {
    now = M._now,
    date = M._date,
    strptime = M._strptime,
  })
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Remove all parley extmarks from `bufnr`.
---
--- @param bufnr integer  Target buffer
function M.clear(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, M._get_ns(), 0, -1)
end

--- Place extmarks on all commented lines in `bufnr`.
---
--- Clears any previously-placed parley extmarks before placing new ones, so
--- calling render twice is idempotent (no duplicates).
---
--- @param bufnr       integer                              Target buffer
--- @param discussions parley.Discussion[]                  All discussions for this buffer's file
--- @param mappings    table<string, parley.anchor.Mapping> Keyed by discussion.id
--- @param opts        { signs: parley.SignsConfig, virtual_text: parley.VirtualTextConfig }
function M.render(bufnr, discussions, mappings, opts)
  M.clear(bufnr)

  local ns = M._get_ns()

  for _, disc in ipairs(discussions) do
    local mapping = mappings[disc.id]

    -- Skip if no mapping or if the anchored line was deleted locally.
    if not mapping or mapping.local_line == nil then
      goto continue
    end

    local stale = mapping.stale
    local hl_sign = stale and HL_STALE_SIGN or HL_SIGN
    local hl_vtext_meta = stale and HL_STALE_VTEXT_META or HL_VTEXT_META
    local hl_vtext = stale and HL_STALE_VTEXT or HL_VTEXT

    -- Extmark options (always placed; sign/vtext conditional on config).
    --- @type table
    local ext_opts = {}

    -- Gutter sign.
    if opts.signs.enabled then
      ext_opts.sign_text = opts.signs.text
      ext_opts.sign_hl_group = hl_sign
    end

    -- Virtual lines below the anchored line: metadata, full multiline body,
    -- then a compact summary when the discussion has additional comments.
    if opts.virtual_text.enabled then
      local first = model.first_comment(disc)
      if first then
        ext_opts.virt_lines = {
          {
            {
              string.format("%s · %s", first.author, format_comment_timestamp(first.created_at)),
              hl_vtext_meta,
            },
          },
        }
        for _, line in ipairs(vim.split(first.body.text, "\n", { plain = true })) do
          ext_opts.virt_lines[#ext_opts.virt_lines + 1] = {
            { M._truncate(line, opts.virtual_text.max_width), hl_vtext },
          }
        end
        local more_comments = model.comment_count(disc) - 1
        if more_comments > 0 then
          local suffix = more_comments == 1 and "comment" or "comments"
          ext_opts.virt_lines[#ext_opts.virt_lines + 1] = {
            { string.format("(%d more %s)", more_comments, suffix), hl_vtext },
          }
        end
      end
    end

    -- Row is 0-indexed; local_line is 1-indexed.
    vim.api.nvim_buf_set_extmark(bufnr, ns, mapping.local_line - 1, 0, ext_opts)

    ::continue::
  end
end

return M
