--- parley.mock_provider — In-memory mock implementation of parley.Provider.
---
--- Designed for use in tests: no network calls, no filesystem access.
--- State is held in `mock.state` and mutated by write operations so that
--- subsequent reads reflect the change (just like a real provider would).
---
--- Call tracking: every method appends a record to `mock.calls.<method>`,
--- allowing tests to assert that the correct calls were made with the
--- expected arguments.
---
--- Configurable errors: call `mock:set_error(method_name, message)` to make
--- any method raise an error on the next (and every subsequent) call.
--- Call `mock:clear_error(method_name)` to remove it.

local provider = require("parley.provider")
local model = require("parley.model")

local M = {}

-- ---------------------------------------------------------------------------
-- Known review events (validated by submit_review)
-- ---------------------------------------------------------------------------

--- @type table<string, string>  event -> resulting review_status
local REVIEW_EVENT_STATUS = {
  approve = "approved",
  request_changes = "changes_requested",
  comment = "commented",
}

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Find a Discussion by id inside a list.
---@param discussions parley.Discussion[]
---@param id string
---@return parley.Discussion|nil, integer|nil  discussion, index
local function find_discussion(discussions, id)
  for i, d in ipairs(discussions) do
    if d.id == id then
      return d, i
    end
  end
  return nil, nil
end

--- Find a Comment by id across all discussions.
---@param discussions parley.Discussion[]
---@param comment_id string
---@return parley.Comment|nil, parley.Discussion|nil  comment, owning discussion
local function find_comment(discussions, comment_id)
  for _, d in ipairs(discussions) do
    for _, c in ipairs(d.comments) do
      if c.id == comment_id then
        return c, d
      end
    end
  end
  return nil, nil
end

--- Generate a unique string id using a per-mock counter.
---@param mock table  the mock instance (for its counter)
---@return string
local function next_id(mock)
  mock._id_counter = mock._id_counter + 1
  return tostring(mock._id_counter)
end

--- Deep-copy a table so that consumers cannot mutate internal state directly.
---@param t table
---@return table
local function deep_copy(t)
  if type(t) ~= "table" then
    return t
  end
  local copy = {}
  for k, v in pairs(t) do
    copy[k] = deep_copy(v)
  end
  return copy
end

-- ---------------------------------------------------------------------------
-- Constructor
-- ---------------------------------------------------------------------------

--- Create a new mock provider.
---
--- @param opts {
---   token?: string,
---   pr?: parley.PR,
---   discussions?: parley.Discussion[],
---   head_sha?: string,
---   write_context?: table,
--- }
--- @return table  A mock that satisfies parley.Provider
function M.new(opts)
  opts = opts or {}

  --- Internal mutable state.
  --- @class parley.MockState
  --- @field token       string
  --- @field pr          parley.PR|nil
  --- @field head_sha    string
  --- @field write_context table|nil
  --- @field discussions parley.Discussion[]

  local mock = {
    --- @type parley.MockState
    state = {
      token = opts.token or "",
      pr = opts.pr and deep_copy(opts.pr) or nil,
      head_sha = opts.head_sha or "",
      write_context = opts.write_context and deep_copy(opts.write_context) or nil,
      discussions = opts.discussions and deep_copy(opts.discussions) or {},
    },

    --- Per-method call log.
    --- @type table<string, table[]>
    calls = {},

    --- Per-method configured errors (nil = no error).
    --- @type table<string, string>
    _errors = {},

    --- Monotonically increasing id counter.
    _id_counter = 0,
  }

  -- Initialise an empty list for every required method name.
  for _, name in ipairs(provider.METHOD_NAMES) do
    mock.calls[name] = {}
  end

  --------------------------------------------------------------------------
  -- Error configuration helpers
  --------------------------------------------------------------------------

  --- Configure a method to raise `message` on every call.
  ---@param self table
  ---@param method_name string
  ---@param message string
  function mock:set_error(method_name, message)
    self._errors[method_name] = message
  end

  --- Remove a configured error for a method.
  ---@param self table
  ---@param method_name string
  function mock:clear_error(method_name)
    self._errors[method_name] = nil
  end

  --- Check and raise a configured error, if any.
  ---@param self table
  ---@param method_name string
  local function check_error(self, method_name)
    local msg = self._errors[method_name]
    if msg then
      error(msg, 2)
    end
  end

  --------------------------------------------------------------------------
  -- auth
  --------------------------------------------------------------------------

  ---@param self table
  ---@return string
  function mock:auth()
    check_error(self, "auth")
    table.insert(self.calls.auth, {})
    return self.state.token
  end

  --------------------------------------------------------------------------
  -- detect_pr
  --------------------------------------------------------------------------

  ---@param self table
  ---@param repo_root string
  ---@param branch string
  ---@return parley.DetectedReview|nil
  function mock:detect_pr(repo_root, branch)
    check_error(self, "detect_pr")
    table.insert(self.calls.detect_pr, { repo_root = repo_root, branch = branch })
    if not self.state.pr then
      return nil
    end
    return {
      pr = deep_copy(self.state.pr),
      head_sha = self.state.head_sha,
      write_context = deep_copy(self.state.write_context),
    }
  end

  --------------------------------------------------------------------------
  -- fetch_discussions
  --------------------------------------------------------------------------

  ---@param self table
  ---@param review parley.DetectedReview
  ---@return parley.Discussion[]
  function mock:fetch_discussions(review)
    check_error(self, "fetch_discussions")
    table.insert(self.calls.fetch_discussions, { review = review, pr = review and review.pr or nil })
    return deep_copy(self.state.discussions)
  end

  --------------------------------------------------------------------------
  -- post_top_level_comment
  --------------------------------------------------------------------------

  ---@param self table
  ---@param review parley.DetectedReview
  ---@param file string
  ---@param anchor parley.Anchor
  ---@param body parley.Body
  ---@return parley.Comment
  function mock:post_top_level_comment(review, file, anchor, body)
    check_error(self, "post_top_level_comment")
    table.insert(self.calls.post_top_level_comment, {
      review = review,
      pr = review and review.pr or nil,
      file = file,
      anchor = deep_copy(anchor),
      body = body,
    })

    local comment_id = next_id(self)
    local comment = model.new_comment({
      id = comment_id,
      author = self.state.token ~= "" and self.state.token or "mock-user",
      body = body,
      created_at = "2024-01-01T00:00:00Z",
      updated_at = "2024-01-01T00:00:00Z",
      is_own = true,
    })

    local discussion_id = next_id(self)
    local discussion = model.new_discussion({
      id = discussion_id,
      file = file,
      line = anchor.start_line,
      end_line = anchor.end_line,
      comments = { comment },
    })

    table.insert(self.state.discussions, discussion)
    return deep_copy(comment)
  end

  ---@param self table
  ---@param review parley.DetectedReview
  ---@param file string
  ---@param anchor parley.Anchor
  ---@param body parley.Body
  ---@param callback fun(result: { ok: boolean, comment?: parley.Comment, err?: string, cancelled?: boolean }): nil
  ---@return { cancel: fun(): nil }
  function mock:begin_post_top_level_comment(review, file, anchor, body, callback)
    local cancelled = false
    vim.schedule(function()
      if cancelled then
        callback({ ok = false, cancelled = true })
        return
      end

      local ok, result = pcall(function()
        return self:post_top_level_comment(review, file, anchor, body)
      end)
      if ok then
        callback({ ok = true, comment = result })
      else
        callback({ ok = false, err = tostring(result) })
      end
    end)

    return {
      cancel = function()
        cancelled = true
      end,
    }
  end

  --------------------------------------------------------------------------
  -- reply
  --------------------------------------------------------------------------

  ---@param self table
  ---@param review parley.DetectedReview
  ---@param discussion parley.Discussion
  ---@param parent_comment parley.Comment
  ---@param body parley.Body
  ---@return parley.Comment
  function mock:reply(review, discussion, parent_comment, body)
    check_error(self, "reply")
    table.insert(self.calls.reply, {
      review = review,
      pr = review and review.pr or nil,
      discussion = deep_copy(discussion),
      parent_comment = deep_copy(parent_comment),
      body = body,
    })

    local stored_discussion = find_discussion(self.state.discussions, discussion.id)
    if not stored_discussion then
      error("discussion not found: " .. discussion.id, 2)
    end

    local parent = find_comment({ stored_discussion }, parent_comment.id)
    if not parent then
      error("parent comment not found: " .. parent_comment.id, 2)
    end

    local comment_id = next_id(self)
    local comment = model.new_comment({
      id = comment_id,
      author = self.state.token ~= "" and self.state.token or "mock-user",
      body = body,
      created_at = "2024-01-01T00:00:00Z",
      updated_at = "2024-01-01T00:00:00Z",
      is_own = true,
      parent_comment_id = parent_comment.id,
    })

    table.insert(stored_discussion.comments, comment)
    return deep_copy(comment)
  end

  ---@param self table
  ---@param review parley.DetectedReview
  ---@param discussion parley.Discussion
  ---@param parent_comment parley.Comment
  ---@param body parley.Body
  ---@param callback fun(result: { ok: boolean, comment?: parley.Comment, err?: string, cancelled?: boolean }): nil
  ---@return { cancel: fun(): nil }
  function mock:begin_reply(review, discussion, parent_comment, body, callback)
    local cancelled = false
    vim.schedule(function()
      if cancelled then
        callback({ ok = false, cancelled = true })
        return
      end

      local ok, result = pcall(function()
        return self:reply(review, discussion, parent_comment, body)
      end)
      if ok then
        callback({ ok = true, comment = result })
      else
        callback({ ok = false, err = tostring(result) })
      end
    end)

    return {
      cancel = function()
        cancelled = true
      end,
    }
  end

  --------------------------------------------------------------------------
  -- resolve
  --------------------------------------------------------------------------

  ---@param self table
  ---@param review parley.DetectedReview
  ---@param discussion_id string
  function mock:resolve(review, discussion_id)
    check_error(self, "resolve")
    table.insert(
      self.calls.resolve,
      { review = review, pr = review and review.pr or nil, discussion_id = discussion_id }
    )

    local discussion = find_discussion(self.state.discussions, discussion_id)
    if not discussion then
      error("discussion not found: " .. discussion_id, 2)
    end
    discussion.resolved = true
  end

  --------------------------------------------------------------------------
  -- unresolve
  --------------------------------------------------------------------------

  ---@param self table
  ---@param review parley.DetectedReview
  ---@param discussion_id string
  function mock:unresolve(review, discussion_id)
    check_error(self, "unresolve")
    table.insert(
      self.calls.unresolve,
      { review = review, pr = review and review.pr or nil, discussion_id = discussion_id }
    )

    local discussion = find_discussion(self.state.discussions, discussion_id)
    if not discussion then
      error("discussion not found: " .. discussion_id, 2)
    end
    discussion.resolved = false
  end

  --------------------------------------------------------------------------
  -- react
  --------------------------------------------------------------------------

  ---@param self table
  ---@param review parley.DetectedReview
  ---@param comment_id string
  ---@param reaction string
  function mock:react(review, comment_id, reaction)
    check_error(self, "react")
    table.insert(
      self.calls.react,
      { review = review, pr = review and review.pr or nil, comment_id = comment_id, reaction = reaction }
    )

    local comment = find_comment(self.state.discussions, comment_id)
    if not comment then
      error("comment not found: " .. comment_id, 2)
    end

    -- Find existing reaction entry of this type.
    local existing = nil
    for _, r in ipairs(comment.reactions) do
      if r.type == reaction then
        existing = r
        break
      end
    end

    if existing then
      if existing.viewer_reacted then
        -- Toggle off: remove viewer's reaction.
        existing.count = existing.count - 1
        existing.viewer_reacted = false
      else
        -- Add viewer's reaction.
        existing.count = existing.count + 1
        existing.viewer_reacted = true
      end
    else
      -- New reaction type.
      table.insert(
        comment.reactions,
        model.new_reaction({
          type = reaction,
          count = 1,
          viewer_reacted = true,
        })
      )
    end
  end

  --------------------------------------------------------------------------
  -- edit
  --------------------------------------------------------------------------

  ---@param self table
  ---@param review parley.DetectedReview
  ---@param comment_id string
  ---@param body parley.Body
  ---@return parley.Comment
  function mock:edit(review, comment_id, body)
    check_error(self, "edit")
    table.insert(
      self.calls.edit,
      { review = review, pr = review and review.pr or nil, comment_id = comment_id, body = body }
    )

    local comment = find_comment(self.state.discussions, comment_id)
    if not comment then
      error("comment not found: " .. comment_id, 2)
    end

    comment.body = body
    comment.updated_at = "2024-01-01T00:00:01Z"
    return deep_copy(comment)
  end

  --------------------------------------------------------------------------
  -- delete
  --------------------------------------------------------------------------

  ---@param self table
  ---@param review parley.DetectedReview
  ---@param comment_id string
  function mock:delete(review, comment_id)
    check_error(self, "delete")
    table.insert(self.calls.delete, { review = review, pr = review and review.pr or nil, comment_id = comment_id })

    local found = false
    for _, discussion in ipairs(self.state.discussions) do
      for i, c in ipairs(discussion.comments) do
        if c.id == comment_id then
          table.remove(discussion.comments, i)
          found = true
          break
        end
      end
      if found then
        break
      end
    end

    if not found then
      error("comment not found: " .. comment_id, 2)
    end
  end

  --------------------------------------------------------------------------
  -- submit_review
  --------------------------------------------------------------------------

  ---@param self table
  ---@param review parley.DetectedReview
  ---@param event string
  ---@param body parley.Body
  function mock:submit_review(review, event, body)
    check_error(self, "submit_review")
    table.insert(
      self.calls.submit_review,
      { review = review, pr = review and review.pr or nil, event = event, body = body }
    )

    local new_status = REVIEW_EVENT_STATUS[event]
    if not new_status then
      error("unknown review event: " .. tostring(event), 2)
    end

    if self.state.pr then
      self.state.pr.review_status = new_status
    end
  end

  return mock
end

return M
