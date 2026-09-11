--- Optimistic comment transactions over shared review snapshots.
local context_repository = require("parley.repositories.context")
local model = require("parley.model")

local next_pending_id = 0

--- @param M table Review repository state
--- @param composite fun(shared: table, view: table): table
--- @param notify_subscribers fun(bufnr: integer, snapshot: table|nil): nil
--- @param build_summary fun(discussions: parley.Discussion[]): table
--- @return table
return function(M, composite, notify_subscribers, build_summary)
  local R = {}

  --- @param discussions parley.Discussion[]
  --- @param discussion_id string
  --- @return parley.Discussion|nil
  local function find_discussion(discussions, discussion_id)
    for _, discussion in ipairs(discussions or {}) do
      if discussion.id == discussion_id then
        return discussion
      end
    end
  end

  --- @param discussions parley.Discussion[]
  --- @param comment_id string
  --- @return parley.Discussion|nil, integer|nil
  local function find_comment(discussions, comment_id)
    for _, discussion in ipairs(discussions or {}) do
      for index, comment in ipairs(discussion.comments or {}) do
        if comment.id == comment_id then
          return discussion, index
        end
      end
    end
  end

  --- @param discussions parley.Discussion[]
  --- @param rel_path string|nil
  --- @return parley.Discussion[]
  local function filter_for_file(discussions, rel_path)
    local result = {}
    for _, discussion in ipairs(discussions or {}) do
      if discussion.file == rel_path then
        result[#result + 1] = discussion
      end
    end
    return result
  end

  --- Publish a table-only mutation without invoking asynchronous line remapping.
  --- Existing mappings remain valid; the source checkout gets an exact mapping
  --- for a newly staged target because write validation proved it clean and at
  --- the loaded review revision immediately before submission.
  --- @param key string
  --- @param shared table
  --- @param mapping_change? { old_id?: string, new_id?: string, remove_id?: string,
  ---   source_bufnr?: integer, file?: string, anchor?: parley.Anchor }
  local function publish(key, shared, mapping_change)
    M._reviews[key] = shared
    for bufnr in pairs(M._key_bufnrs[key] or {}) do
      local old_view = M._views[bufnr] or { discussions = {}, mappings = {}, all_mappings = {} }
      local view = {
        discussions = filter_for_file(shared.all_discussions, (context_repository.get(bufnr) or {}).rel_path),
        mappings = vim.deepcopy(old_view.mappings or {}),
        all_mappings = vim.deepcopy(old_view.all_mappings or {}),
      }
      if mapping_change then
        local old_id, new_id = mapping_change.old_id, mapping_change.new_id
        if old_id and new_id then
          if view.mappings[old_id] then
            view.mappings[new_id], view.mappings[old_id] = view.mappings[old_id], nil
          end
          if view.all_mappings[old_id] then
            view.all_mappings[new_id], view.all_mappings[old_id] = view.all_mappings[old_id], nil
          end
        elseif mapping_change.remove_id then
          view.mappings[mapping_change.remove_id] = nil
          view.all_mappings[mapping_change.remove_id] = nil
        elseif new_id and mapping_change.anchor then
          local ctx = context_repository.get(bufnr)
          local source_ctx = context_repository.get(mapping_change.source_bufnr)
          local same_checkout = ctx
            and source_ctx
            and vim.deep_equal(ctx.vcs_info, source_ctx.vcs_info)
            and ctx.rel_path == mapping_change.file
          local identity_mapped = M._identity_bufnrs[bufnr] == "new" and ctx and ctx.rel_path == mapping_change.file
          if same_checkout or identity_mapped then
            local mapping = {
              local_line = mapping_change.anchor.start_line,
              local_end_line = mapping_change.anchor.end_line,
              confidence = 1.0,
              stale = false,
            }
            view.mappings[new_id] = mapping
            view.all_mappings[new_id] = vim.deepcopy(mapping)
          end
        end
      end
      M._views[bufnr] = view
      notify_subscribers(bufnr, composite(shared, view))
    end
  end

  --- @class parley.PendingCommentToken
  --- @field key string
  --- @field kind 'new'|'reply'
  --- @field pending_id string
  --- @field discussion_id string

  --- @param bufnr integer
  --- @param opts { kind: 'new'|'reply', body: parley.Body, file?: string,
  ---   anchor?: parley.Anchor, discussion_id?: string, parent_comment_id?: string }
  --- @return parley.PendingCommentToken|nil, string|nil
  function R.stage_comment(bufnr, opts)
    local key = M._bufnr_key[bufnr]
    local current = key and M._reviews[key]
    if not key or not current then
      return nil, "review snapshot is no longer available"
    end
    if opts.kind ~= "new" and opts.kind ~= "reply" then
      return nil, "invalid optimistic comment kind"
    end

    local shared = vim.deepcopy(current)
    next_pending_id = next_pending_id + 1
    local pending_id = string.format("parley-pending:%d", next_pending_id)
    local comment = model.new_comment({
      id = pending_id,
      author = "you",
      body = vim.deepcopy(opts.body),
      created_at = "",
      updated_at = "",
      is_own = true,
      parent_comment_id = opts.parent_comment_id,
      pending = true,
    })

    local discussion_id
    local mapping_change
    if opts.kind == "new" then
      if type(opts.file) ~= "string" or type(opts.anchor) ~= "table" then
        return nil, "new optimistic comment target is incomplete"
      end
      discussion_id = pending_id
      shared.all_discussions[#shared.all_discussions + 1] = model.new_discussion({
        id = discussion_id,
        anchor = {
          kind = "inline",
          side = "new",
          path = opts.file,
          line = opts.anchor.start_line,
          end_line = opts.anchor.end_line,
        },
        issue_state = "unknown",
        comments = { comment },
      })
      mapping_change = {
        source_bufnr = bufnr,
        file = opts.file,
        anchor = opts.anchor,
        new_id = discussion_id,
      }
    else
      discussion_id = opts.discussion_id
      local discussion = type(discussion_id) == "string" and find_discussion(shared.all_discussions, discussion_id)
      if not discussion then
        return nil, "reply discussion is no longer available"
      end
      discussion.comments[#discussion.comments + 1] = comment
    end

    shared.summary = build_summary(shared.all_discussions)
    publish(key, shared, mapping_change)
    return {
      key = key,
      kind = opts.kind,
      pending_id = pending_id,
      discussion_id = discussion_id,
    }
  end

  --- @param token parley.PendingCommentToken
  --- @param server_comment parley.Comment
  --- @return string|nil, string|nil Confirmed discussion ID or an error.
  function R.confirm_comment(token, server_comment)
    if type(server_comment) ~= "table" or type(server_comment.id) ~= "string" or server_comment.id == "" then
      return nil, "provider returned no created comment"
    end
    local current = M._reviews[token.key]
    if not current then
      return nil, "review snapshot is no longer available"
    end
    local shared = vim.deepcopy(current)
    local discussion, index = find_comment(shared.all_discussions, token.pending_id)
    local existing = find_comment(shared.all_discussions, server_comment.id)
    if existing and discussion then
      if token.kind == "new" then
        for discussion_index, candidate in ipairs(shared.all_discussions) do
          if candidate.id == token.discussion_id then
            table.remove(shared.all_discussions, discussion_index)
            break
          end
        end
      else
        table.remove(discussion.comments, index)
      end
      shared.summary = build_summary(shared.all_discussions)
      publish(token.key, shared, token.kind == "new" and { remove_id = token.discussion_id } or nil)
      return existing.id
    end
    if not discussion then
      return existing and existing.id or nil, existing and nil or "pending comment is no longer available"
    end

    local confirmed = vim.deepcopy(server_comment)
    confirmed.pending = nil
    discussion.comments[index] = confirmed
    local discussion_id = discussion.id
    local mapping_change
    if token.kind == "new" then
      discussion_id = confirmed.id
      discussion.id = discussion_id
      mapping_change = { old_id = token.discussion_id, new_id = discussion_id }
    end
    shared.summary = build_summary(shared.all_discussions)
    publish(token.key, shared, mapping_change)
    return discussion_id
  end

  --- @param token parley.PendingCommentToken
  --- @return boolean
  function R.rollback_comment(token)
    local current = M._reviews[token.key]
    if not current then
      return false
    end
    local shared = vim.deepcopy(current)
    local discussion, index = find_comment(shared.all_discussions, token.pending_id)
    if not discussion then
      return false
    end
    if token.kind == "new" then
      for discussion_index, candidate in ipairs(shared.all_discussions) do
        if candidate.id == token.discussion_id then
          table.remove(shared.all_discussions, discussion_index)
          break
        end
      end
    else
      table.remove(discussion.comments, index)
    end
    shared.summary = build_summary(shared.all_discussions)
    publish(token.key, shared, token.kind == "new" and { remove_id = token.discussion_id } or nil)
    return true
  end

  --- Return a real source buffer suitable for refreshing an attached shared review.
  --- Diffview aliases have no filesystem path; their host buffer does.
  --- @param bufnr integer
  --- @return integer|nil
  function R.refresh_source(bufnr)
    local key = M._bufnr_key[bufnr]
    local candidates = vim.tbl_keys((key and M._key_bufnrs[key]) or {})
    table.sort(candidates)
    for _, candidate in ipairs(candidates) do
      local ctx = context_repository.get(candidate)
      if vim.api.nvim_buf_is_valid(candidate) and ctx and type(ctx.path) == "string" and ctx.path ~= "" then
        return candidate
      end
    end
  end

  return R
end
