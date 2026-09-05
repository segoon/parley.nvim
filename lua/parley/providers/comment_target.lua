--- Changed-line eligibility shared by the built-in hosting providers.
local M = {}
--- @param info parley.VcsInfo
--- @param base_branch string
--- @param rel_path string
--- @param anch parley.Anchor
--- @param head_sha string
--- @return parley.CommentTargetResult
function M.check(info, base_branch, rel_path, anch, head_sha)
  local diff, err = require("parley.vcs").read_diff(info, base_branch, rel_path, head_sha)
  if not diff then
    return { ok = false, err = "Cannot comment: " .. err }
  end
  if diff == "" then
    return {
      ok = false,
      err = "Cannot comment: '" .. rel_path .. "' has no changes in this PR. Only changed lines can be commented on.",
    }
  end
  local anchor = require("parley.anchor")
  local hunks = anchor.parse_hunks(diff)
  for line = anch.start_line, anch.end_line or anch.start_line do
    if not anchor.is_line_in_hunk(line, hunks) then
      return {
        ok = false,
        err = "Cannot comment: line " .. line .. " is not part of the PR diff. Move the cursor to a changed line.",
      }
    end
  end
  return { ok = true }
end

--- @param _self parley.Provider
--- @param review parley.DetectedReview
--- @param target parley.CommentTarget
--- @return parley.CommentTargetResult
function M.validate(_self, review, target)
  return M.check(target.vcs_info, review.pr.base_branch, target.rel_path, target.anchor, review.head_sha)
end
return M
