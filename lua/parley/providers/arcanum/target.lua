--- Translate source-checkout selections to immutable Arcanum review coordinates.
local content = require("parley.local_content")
local anchor = require("parley.anchor")
local changed = require("parley.providers.comment_target")
local M = {}

--- @param _self parley.arcanum.Provider
--- @param review parley.DetectedReview
--- @param target parley.CommentTarget
--- @return parley.CommentTargetResult
function M.validate(_self, review, target)
  for _, revision in ipairs({ review.head_sha or "", review.base_sha or "", review.review_sha or "" }) do
    if revision == "" then
      return { ok = false, err = "Cannot comment: review revisions are unavailable. Refresh and reopen the draft." }
    end
  end
  local remote = vim.deepcopy(target.anchor)
  local source_revision = target.revision or review.head_sha
  if source_revision ~= review.head_sha and source_revision ~= review.review_sha then
    return { ok = false, err = "Cannot comment: selection belongs to another review revision." }
  end
  if source_revision ~= review.review_sha then
    local before, before_err = content.revision(target.vcs_info, review.head_sha, target.rel_path)
    local after, after_err = content.revision(target.vcs_info, review.review_sha, target.rel_path)
    if not before or not after then
      return { ok = false, err = "Cannot comment: " .. (before_err or after_err or "review content unavailable") }
    end
    if before:find("\0", 1, true) or after:find("\0", 1, true) then
      return { ok = false, err = "Cannot comment: binary content cannot be mapped." }
    end
    local hunks = anchor.parse_hunks(vim.diff(content.normalize(before), content.normalize(after), { ctxlen = 0 }))
    local first
    for line = target.anchor.start_line, target.anchor.end_line or target.anchor.start_line do
      local mapped = anchor.remap_line(line, hunks)
      first = first or mapped.local_line
      if mapped.stale or not mapped.local_line or mapped.local_line ~= first + line - target.anchor.start_line then
        return {
          ok = false,
          err = "Cannot comment: selected lines differ in the review merge. Refresh and select an unchanged range.",
        }
      end
    end
    remote.start_line = first
    remote.end_line = target.anchor.end_line and first + target.anchor.end_line - target.anchor.start_line or nil
  end
  local result = changed.check(target.vcs_info, review.base_sha, target.rel_path, remote, review.review_sha)
  if result.ok then
    result.anchor = remote
  end
  return result
end
return M
