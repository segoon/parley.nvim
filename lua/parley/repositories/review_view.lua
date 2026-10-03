--- Compute checkout and immutable-buffer projections of a remote snapshot.
local context_repository = require("parley.repositories.context")
local local_mappings = require("parley.repositories.local_mappings")
local semantics = require("parley.discussion")
--- @param M table Review repository state
--- @param scope_matches fun(bufnr: integer, shared: table): boolean
--- @return fun(bufnr: integer, shared: table): table|nil
return function(M, scope_matches)
  --- @param discussions parley.Discussion[]
  --- @param rel_path string
  --- @return parley.Discussion[]
  local function filter_for_file(discussions, rel_path)
    local out = {}
    for _, discussion in ipairs(discussions) do
      if discussion.file == rel_path then
        out[#out + 1] = discussion
      end
    end
    return out
  end
  --- Compute the per-file view for a buffer from shared review data.
  --- @param bufnr integer
  --- @param shared table
  --- @return { discussions: parley.Discussion[], mappings: table }
  local function compute_view(bufnr, shared)
    local ctx = context_repository.get(bufnr)
    local rel_path = ctx and ctx.rel_path or nil
    if not rel_path then
      return { discussions = {}, mappings = {} }
    end
    local file_discussions = filter_for_file(shared.all_discussions or {}, rel_path)

    local identity_side = M._identity_bufnrs[bufnr]
    if identity_side then
      local mappings = {}
      for _, discussion in ipairs(file_discussions) do
        local a = semantics.anchor(discussion)
        local disc_side = a.side == "old" and "old" or "new"
        -- Same conditions as semantics.projectable(), except side is matched
        -- against the buffer's own side instead of hardcoding "new" — an
        -- old-side anchor only has a meaningful position in an old-side
        -- buffer, and projectable() itself always excludes side == "old"
        -- (it's meant for regular, working-tree-relative buffers).
        if
          a.kind == "inline"
          and semantics.valid_path(a.path)
          and semantics.valid_line(a.line)
          and not a.unavailable_reason
          and disc_side == identity_side
          and (
            not ctx.revision
            or ctx.revision
              == (a.revision or (shared.review and (shared.review.review_sha or shared.review.head_sha)))
          )
        then
          mappings[discussion.id] = {
            local_line = discussion.line,
            local_end_line = discussion.end_line,
            confidence = 1.0,
            stale = false,
          }
        end
      end
      return { discussions = file_discussions, mappings = mappings, all_mappings = mappings }
    end

    local all_mappings = local_mappings.get(ctx, shared)
    local current = context_repository.get(bufnr)
    if not current or not vim.deep_equal(current.vcs_info, ctx.vcs_info) or current.rel_path ~= rel_path then
      return nil
    end
    if not all_mappings or not scope_matches(bufnr, shared) then
      return nil
    end
    local mappings = {}
    for _, discussion in ipairs(file_discussions) do
      local mapping = all_mappings and all_mappings[discussion.id] or nil
      if mapping then
        mappings[discussion.id] = mapping
      end
    end
    return {
      discussions = file_discussions,
      mappings = mappings,
      all_mappings = all_mappings,
    }
  end
  return compute_view
end
