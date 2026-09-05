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

--- @class parley.ReactionPresentation
--- @field label string
--- @field emoji? string
--- @class parley.ReactionChoice : parley.ReactionPresentation
--- @field reaction string Opaque provider identifier
--- @field remove_only? boolean
--- @class parley.ReviewActionChoice
--- @field action string
--- @field label string
--- @field confirmation string
--- @field reason? string Unavailable action explanation

--- The abstract provider interface.
---
--- All methods are called as `provider:method(...)` (colon syntax).
--- Yielding operation methods run in a Plenary async context. Optional begin_*
--- starters run without yielding; their callbacks run on the main loop, inline
--- or later. Local presentation hooks do not yield.
---
--- @class parley.Anchor
--- @field start_line integer
--- @field end_line integer|nil
---
--- @class parley.DetectedReview
--- @field pr parley.PR
--- @field head_sha string
--- @field write_context table|nil
---
--- @class parley.CacheIdentity
--- @field provider string
--- @field host string
--- @field repository string
--- @field account string Non-secret fingerprint of local credential context

--- @class parley.CommentTarget
--- @field vcs_info parley.VcsInfo
--- @field rel_path string
--- @field anchor parley.Anchor
--- @alias parley.CommentTargetResult {ok: true}|{ok: false, err: string}

--- @class parley.WriteResult
--- @field ok boolean
--- @field comment? parley.Comment
--- @field err? string
--- @field refresh? boolean Refresh remote state after a known conflict.
--- @field cancelled? boolean Must not be true when ok is true.
--- @field uncertain? boolean The server may have accepted the mutation; check the review before retrying.
--- @alias parley.WriteCallback fun(result: parley.WriteResult): nil
--- @class parley.CancelHandle
--- @field cancel fun(): nil Request cancellation; completion arrives through the callback.

--- @class parley.Provider
--- Async initialization before publishing cache identity.
--- @field review_actions? fun(self: parley.Provider,
--- review: parley.DetectedReview): parley.ReviewActionChoice[], string|nil
--- @field begin_review_action? fun(self: parley.Provider, review: parley.DetectedReview,
--- action: string, callback: parley.WriteCallback): parley.CancelHandle
--- @field begin_set_reaction? fun(self: parley.Provider, review: parley.DetectedReview,
--- comment_id: string, code: string, present: boolean, callback: parley.WriteCallback): parley.CancelHandle
--- @field prepare? fun(self: parley.Provider, info?: parley.VcsInfo)
--- Local-only implemented actions, not token authorization.
--- @field capabilities? fun(self: parley.Provider, review: parley.DetectedReview): parley.ProviderCapabilities
--- @field begin_resolve? fun(self: parley.Provider, review: parley.DetectedReview,
--- discussion_id: string, callback: parley.WriteCallback): parley.CancelHandle
--- @field begin_unresolve? fun(self: parley.Provider, review: parley.DetectedReview,
--- discussion_id: string, callback: parley.WriteCallback): parley.CancelHandle
--- @field validate_comment_target fun(
---   self: parley.Provider, review: parley.DetectedReview, target: parley.CommentTarget
--- ): parley.CommentTargetResult
--- @field display_name string Nonblank human-readable provider name; local metadata.
--- @field cache_identity fun(self: parley.Provider): parley.CacheIdentity|nil
--- Return the authentication token for API calls.
--- @field auth fun(self: parley.Provider): string
---
--- Detect an open PR for the given repo root and branch identifier.
--- Returns nil when no PR is found (plugin should silently deactivate).
--- @field detect_pr fun(self: parley.Provider, repo_root: string, branch: string): parley.DetectedReview|nil
---
--- Fetch all discussions for a PR.
--- @field fetch_discussions fun(self: parley.Provider, review: parley.DetectedReview): parley.Discussion[]
---
--- Post a new top-level comment anchored to a file/line or line range.
--- Returns the newly created Comment.
--- @field post_top_level_comment fun(
---   self: parley.Provider,
---   review: parley.DetectedReview,
---   file: string,
---   anchor: parley.Anchor,
---   body: parley.Body): parley.Comment
---
--- Post a reply to an existing discussion.
--- Returns the newly created Comment.
--- @field reply fun(self: parley.Provider, review: parley.DetectedReview, discussion: parley.Discussion,
---   parent_comment: parley.Comment, body: parley.Body): parley.Comment
---
--- Mark a discussion as resolved.
--- @field resolve fun(self: parley.Provider, review: parley.DetectedReview, discussion_id: string)
---
--- Mark a discussion as unresolved.
--- @field unresolve fun(self: parley.Provider, review: parley.DetectedReview, discussion_id: string)
---
--- Toggle a reaction on a comment (add if absent, remove if present).
--- @field react fun(self: parley.Provider, review: parley.DetectedReview, comment_id: string, reaction: string)
---
--- Edit an existing comment body. Returns the updated Comment.
--- @field edit fun(
---   self: parley.Provider,
---   review: parley.DetectedReview,
---   comment_id: string,
---   body: parley.Body
--- ): parley.Comment
---
--- Delete a comment.
--- @field delete fun(self: parley.Provider, review: parley.DetectedReview, comment_id: string)
---
--- Submit a PR-level review.
--- `event` is one of: "approve", "request_changes", "comment".
--- @field submit_review fun(self: parley.Provider, review: parley.DetectedReview, event: string, body: parley.Body)
---
--- Return a short human-readable label for use in progress messages,
--- e.g. "github.com" or "github.mycompany.com".
--- @field progress_label fun(self: parley.Provider): string

--- Optional cancellable operations. Return promptly without yielding and invoke
--- the callback exactly once on the main loop, including after cancellation.
--- @field begin_post_top_level_comment? fun(
---   self: parley.Provider, review: parley.DetectedReview, file: string, anchor: parley.Anchor,
---   body: parley.Body, callback: parley.WriteCallback
--- ): parley.CancelHandle
--- @field begin_reply? fun(
---   self: parley.Provider, review: parley.DetectedReview, discussion: parley.Discussion,
---   parent_comment: parley.Comment, body: parley.Body, callback: parley.WriteCallback
--- ): parley.CancelHandle

--- Optional local-only metadata; missing choices means mutation is unavailable.
--- @field reaction_choices? fun(self: parley.Provider, review: parley.DetectedReview,
--- comment: parley.Comment): parley.ReactionChoice[], string|nil
--- @field reaction_presentation? fun(self: parley.Provider, code: string): parley.ReactionPresentation

-- ---------------------------------------------------------------------------
-- Required method names (single source of truth)
-- ---------------------------------------------------------------------------

--- Ordered list of every method a provider must expose.
--- Used by validate() and by mock_provider to initialise its calls table.
--- @type string[]
M.METHOD_NAMES = {
  "validate_comment_target",
  "cache_identity",
  "auth",
  "detect_pr",
  "fetch_discussions",
  "post_top_level_comment",
  "reply",
  "resolve",
  "unresolve",
  "react",
  "edit",
  "delete",
  "submit_review",
  "progress_label",
}

--- Optional methods are validated when present; absence preserves fallback behavior.
--- @type string[]
M.OPTIONAL_METHOD_NAMES = {
  "review_actions",
  "begin_review_action",
  "begin_set_reaction",
  "prepare",
  "capabilities",
  "begin_resolve",
  "begin_unresolve",
  "begin_post_top_level_comment",
  "begin_reply",
  "reaction_choices",
  "reaction_presentation",
}

-- ---------------------------------------------------------------------------
-- Interface validation
-- ---------------------------------------------------------------------------

--- Return true iff `p` implements the parley.Provider interface.
---
--- Checks:
---   • `p` is a non-nil table.
---   • Every name in METHOD_NAMES is present and is a function.
---   • display_name is a nonblank string.
---   • Every present optional method is a function.
---
--- @param p any
--- @return boolean
function M.validate(p)
  if type(p) ~= "table" then
    return false
  end
  if type(p.display_name) ~= "string" or not p.display_name:find("%S") then
    return false
  end
  for _, name in ipairs(M.METHOD_NAMES) do
    if type(p[name]) ~= "function" then
      return false
    end
  end
  for _, name in ipairs(M.OPTIONAL_METHOD_NAMES) do
    if p[name] ~= nil and type(p[name]) ~= "function" then
      return false
    end
  end
  return true
end

return M
