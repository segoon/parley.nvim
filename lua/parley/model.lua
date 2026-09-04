--- parley.model — Discussion data model.
---
--- Defines the normalized types that all providers produce and all UI code
--- consumes. Plain tables throughout — no metatables — so values round-trip
--- through vim.json.encode / vim.json.decode safely (required for disk cache).
---
--- All constructors assert required fields and apply defaults for optional
--- ones. Helper functions operate on plain tables; callers keep a reference to
--- this module.

local M = {}

-- ---------------------------------------------------------------------------
-- Known-value sets (single source of truth for validation)
-- ---------------------------------------------------------------------------

--- @type table<string, true>
local KNOWN_BODY_FORMATS = {
  markdown = true,
  plaintext = true,
}

--- @type table<string, true>
local KNOWN_REVIEW_STATUSES = {
  approved = true,
  changes_requested = true,
  pending = true,
  dismissed = true,
  commented = true,
}

-- ---------------------------------------------------------------------------
-- Type annotations
-- ---------------------------------------------------------------------------

--- The textual content of a comment, with its serialization format.
--- @class parley.Body
--- @field text   string  Raw content
--- @field format string  One of the KNOWN_BODY_FORMATS values

--- A single emoji/reaction entry on a comment.
--- @class parley.Reaction
--- @field type           string   Opaque provider reaction identifier
--- @field count          integer  Number of users who reacted
--- @field viewer_reacted boolean  Whether the current auth user has reacted

--- A single comment within a Discussion.
--- @class parley.Comment
--- @field id                string             Provider-specific comment ID
--- @field author            string             Username of the comment author
--- @field body              parley.Body
--- @field created_at        string             ISO-8601 timestamp
--- @field updated_at        string             ISO-8601 timestamp
--- @field reactions         parley.Reaction[]
--- @field is_own            boolean            Current auth user is the author
--- @field parent_comment_id string|nil         nil = root; non-nil = reply

--- A discussion anchored to a specific file location in a PR.
--- Comments are stored as a flat list ordered by created_at; renderers
--- reconstruct trees using parent_comment_id where needed.
--- @class parley.Discussion
--- @field id       string             Provider-specific discussion ID
--- @field file     string             Repo-relative file path
--- @field line     integer            Start line (1-indexed, in PR diff space)
--- @field end_line integer|nil        nil = single line
--- @field resolved boolean
--- @field comments parley.Comment[]

--- @alias parley.ReviewStatus
--- | "approved"
--- | "changes_requested"
--- | "pending"
--- | "dismissed"
--- | "commented"

--- Metadata for a pull / merge request.
--- @class parley.PR
--- @field id            string                Provider-specific PR/MR identifier
--- @field title         string
--- @field state         string                "open" | "closed" | "merged"
--- @field base_branch   string
--- @field head_branch   string
--- @field author        string
--- @field url           string
--- @field review_status parley.ReviewStatus

-- ---------------------------------------------------------------------------
-- Constructors
-- ---------------------------------------------------------------------------

--- Create a new Body.
--- @param opts { text: string, format: string }
--- @return parley.Body
function M.new_body(opts)
  assert(type(opts.text) == "string", "body.text must be a string")
  assert(type(opts.format) == "string", "body.format must be a string")
  assert(KNOWN_BODY_FORMATS[opts.format], "unknown body format: " .. opts.format)
  return { text = opts.text, format = opts.format }
end

--- Create a new Reaction.
--- @param opts { type: string, count: integer, viewer_reacted: boolean }
--- @return parley.Reaction
function M.new_reaction(opts)
  assert(type(opts.type) == "string", "reaction.type must be a string")
  assert(type(opts.count) == "number", "reaction.count must be a number")
  assert(type(opts.viewer_reacted) == "boolean", "reaction.viewer_reacted must be a boolean")
  return { type = opts.type, count = opts.count, viewer_reacted = opts.viewer_reacted }
end

--- Create a new Comment.
---
--- Required: id, author, body, created_at, updated_at.
--- Defaults: reactions = {}, is_own = false, parent_comment_id = nil.
---
--- @param opts table
--- @return parley.Comment
function M.new_comment(opts)
  assert(type(opts.id) == "string", "comment.id must be a string")
  assert(type(opts.author) == "string", "comment.author must be a string")
  assert(type(opts.body) == "table", "comment.body must be a parley.Body table")
  assert(type(opts.created_at) == "string", "comment.created_at must be a string")
  assert(type(opts.updated_at) == "string", "comment.updated_at must be a string")
  return {
    id = opts.id,
    author = opts.author,
    body = opts.body,
    created_at = opts.created_at,
    updated_at = opts.updated_at,
    reactions = opts.reactions or {},
    is_own = opts.is_own or false,
    parent_comment_id = opts.parent_comment_id or nil,
  }
end

--- Create a new Discussion.
---
--- Required: id, file, line, comments.
--- Defaults: resolved = false, end_line = nil.
---
--- @param opts table
--- @return parley.Discussion
function M.new_discussion(opts)
  assert(type(opts.id) == "string", "discussion.id must be a string")
  assert(type(opts.file) == "string", "discussion.file must be a string")
  assert(type(opts.line) == "number", "discussion.line must be a number")
  assert(type(opts.comments) == "table", "discussion.comments must be a table")
  return {
    id = opts.id,
    file = opts.file,
    line = opts.line,
    end_line = opts.end_line or nil,
    resolved = opts.resolved or false,
    comments = opts.comments,
  }
end

--- Create a new PR.
---
--- All fields are required.
---
--- @param opts table
--- @return parley.PR
function M.new_pr(opts)
  assert(type(opts.id) == "string", "pr.id must be a string")
  assert(type(opts.title) == "string", "pr.title must be a string")
  assert(type(opts.state) == "string", "pr.state must be a string")
  assert(type(opts.base_branch) == "string", "pr.base_branch must be a string")
  assert(type(opts.head_branch) == "string", "pr.head_branch must be a string")
  assert(type(opts.author) == "string", "pr.author must be a string")
  assert(type(opts.url) == "string", "pr.url must be a string")
  assert(type(opts.review_status) == "string", "pr.review_status must be a string")
  assert(KNOWN_REVIEW_STATUSES[opts.review_status], "unknown review_status: " .. opts.review_status)
  return {
    id = opts.id,
    title = opts.title,
    state = opts.state,
    base_branch = opts.base_branch,
    head_branch = opts.head_branch,
    author = opts.author,
    url = opts.url,
    review_status = opts.review_status,
  }
end

-- ---------------------------------------------------------------------------
-- Discussion helpers
-- ---------------------------------------------------------------------------

--- Return whether a Discussion is marked as resolved.
--- @param discussion parley.Discussion
--- @return boolean
function M.is_resolved(discussion)
  return discussion.resolved
end

--- Return the first Comment in the Discussion, or nil if there are none.
--- @param discussion parley.Discussion
--- @return parley.Comment|nil
function M.first_comment(discussion)
  return discussion.comments[1]
end

--- Return the total number of Comments in the Discussion.
--- @param discussion parley.Discussion
--- @return integer
function M.comment_count(discussion)
  return #discussion.comments
end

-- ---------------------------------------------------------------------------
-- Comment helpers
-- ---------------------------------------------------------------------------

--- Return whether a Comment is a reply (has a parent_comment_id).
--- @param comment parley.Comment
--- @return boolean
function M.is_reply(comment)
  return comment.parent_comment_id ~= nil
end

-- ---------------------------------------------------------------------------
-- Body helpers
-- ---------------------------------------------------------------------------

--- Return whether a Body uses Markdown format.
--- @param body parley.Body
--- @return boolean
function M.is_markdown(body)
  return body.format == "markdown"
end

return M
