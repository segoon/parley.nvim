--- parley.provider — Abstract provider interface definition.
---
--- Defines the contract that every hosting-provider implementation must satisfy.
--- Contains:
---   • LuaCats type annotations for the provider interface.
---   • METHOD_NAMES — the canonical list of required method names.
---   • validate(p) — returns true iff `p` satisfies the interface.
---
--- No real implementation lives here. See mock_provider.lua for a test double
--- and the github/ sub-tree (Phase 1) for the first real provider.

local M = {}

-- ---------------------------------------------------------------------------
-- Type annotations
-- ---------------------------------------------------------------------------

--- The abstract provider interface.
---
--- All methods are called as `provider:method(...)` (colon syntax).
--- Async providers must wrap blocking calls in `plenary.async.run`; callers
--- always invoke methods from within a plenary async context.
---
--- @class parley.Provider
---
--- Return the authentication token for API calls.
--- @field auth fun(self: parley.Provider): string
---
--- Detect an open PR for the given repo root and branch.
--- Returns nil when no PR is found (plugin should silently deactivate).
--- @field detect_pr fun(self: parley.Provider, repo_root: string, branch: string): parley.PR|nil
---
--- Fetch all discussions for a PR.
--- @field fetch_discussions fun(self: parley.Provider, pr: parley.PR): parley.Discussion[]
---
--- Post a new top-level comment anchored to a file/line.
--- Returns the newly created Comment.
--- @field post_comment fun(self: parley.Provider, pr: parley.PR, file: string, line: integer, body: parley.Body): parley.Comment
---
--- Post a reply to an existing discussion.
--- Returns the newly created Comment.
--- @field reply fun(self: parley.Provider, pr: parley.PR, discussion_id: string, body: parley.Body): parley.Comment
---
--- Mark a discussion as resolved.
--- @field resolve fun(self: parley.Provider, pr: parley.PR, discussion_id: string)
---
--- Mark a discussion as unresolved.
--- @field unresolve fun(self: parley.Provider, pr: parley.PR, discussion_id: string)
---
--- Toggle a reaction on a comment (add if absent, remove if present).
--- @field react fun(self: parley.Provider, pr: parley.PR, comment_id: string, reaction: string)
---
--- Edit an existing comment body. Returns the updated Comment.
--- @field edit fun(self: parley.Provider, pr: parley.PR, comment_id: string, body: parley.Body): parley.Comment
---
--- Delete a comment.
--- @field delete fun(self: parley.Provider, pr: parley.PR, comment_id: string)
---
--- Submit a PR-level review.
--- `event` is one of: "approve", "request_changes", "comment".
--- @field submit_review fun(self: parley.Provider, pr: parley.PR, event: string, body: parley.Body)

-- ---------------------------------------------------------------------------
-- Required method names (single source of truth)
-- ---------------------------------------------------------------------------

--- Ordered list of every method a provider must expose.
--- Used by validate() and by mock_provider to initialise its calls table.
--- @type string[]
M.METHOD_NAMES = {
  "auth",
  "detect_pr",
  "fetch_discussions",
  "post_comment",
  "reply",
  "resolve",
  "unresolve",
  "react",
  "edit",
  "delete",
  "submit_review",
}

-- ---------------------------------------------------------------------------
-- Interface validation
-- ---------------------------------------------------------------------------

--- Return true iff `p` implements the parley.Provider interface.
---
--- Checks:
---   • `p` is a non-nil table.
---   • Every name in METHOD_NAMES is present and is a function.
---
--- @param p any
--- @return boolean
function M.validate(p)
  if type(p) ~= "table" then
    return false
  end
  for _, name in ipairs(M.METHOD_NAMES) do
    if type(p[name]) ~= "function" then
      return false
    end
  end
  return true
end

return M
