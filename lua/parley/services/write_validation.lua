--- Shared validation for opening and submitting inline drafts.
local context_repository = require("parley.repositories.context")
local provider_repository = require("parley.repositories.provider")
local review_repository = require("parley.repositories.review")
local write_contexts = require("parley.services.write_context")
local autorefresh = require("parley.services.autorefresh")
--- @param M table Write service seams
--- @return table
return function(M)
  --- @param bufnr integer
  --- @param expected table
  local function autorefresh_stale_review(bufnr, expected)
    autorefresh.once(
      bufnr,
      "write_context:" .. tostring(expected.review.pr.id) .. "|" .. tostring(expected.review.head_sha),
      function()
        review_repository.refresh_async(bufnr, { force = true, notify_errors = false })
      end
    )
  end
  --- Invoke provider eligibility and fail closed on contract errors.
  --- @param context table
  --- @param anch parley.Anchor
  --- @return string|nil, parley.Anchor|nil
  local function validate_target(context, anch)
    local ok, result = pcall(
      context.provider.validate_comment_target,
      context.provider,
      context.review,
      { vcs_info = context.vcs_info, rel_path = context.rel_path, anchor = anch, revision = context.revision }
    )
    if not ok then
      return "Cannot comment: " .. tostring(result)
    end
    if
      type(result) ~= "table"
      or type(result.ok) ~= "boolean"
      or (not result.ok and (type(result.err) ~= "string" or not result.err:find("%S")))
    then
      return "Cannot comment: provider returned an invalid target validation result."
    end
    if not result.ok then
      return result.err
    end
    local prepared = result.anchor == nil and anch or result.anchor
    local semantics = require("parley.discussion")
    if
      type(prepared) ~= "table"
      or not semantics.valid_line(prepared.start_line)
      or (
        prepared.end_line ~= nil
        and (not semantics.valid_line(prepared.end_line) or prepared.end_line < prepared.start_line)
      )
    then
      return "Cannot comment: provider returned an invalid prepared anchor."
    end
    return nil, prepared
  end

  --- @param bufnr integer
  --- @param expected table
  --- @return boolean
  local function provider_changed(bufnr, expected)
    local snapshot = provider_repository.get(bufnr)
    if not snapshot then
      return true
    end
    if expected.identity_checked then
      local current_identity = snapshot.provider.cache_identity and snapshot.provider:cache_identity()
      return not vim.deep_equal(current_identity, expected.identity)
    end
    return snapshot.provider ~= expected.provider
  end

  --- @param bufnr integer
  --- @param expected table
  --- @param anch parley.Anchor
  --- @return string|nil, parley.Anchor|nil
  local function validate_submission(bufnr, expected, anch)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return "Source buffer is no longer available"
    end
    local reason = write_contexts.reason(bufnr, "post_top_level_comment", expected)
    if reason then
      return reason
    end
    local tick = vim.api.nvim_buf_get_changedtick(bufnr)
    local current = M._refresh_context(bufnr)
    if
      not current
      or current.rel_path ~= expected.rel_path
      or current.revision ~= expected.revision
      or not vim.deep_equal(current.vcs_info, expected.vcs_info)
    then
      return "Cannot comment: repository context changed. Reopen the draft for the current review."
    end
    local snapshot = review_repository.get(bufnr)
    if
      not snapshot
      or not snapshot.review
      or not require("parley.provider").same_review(snapshot.review, expected.review)
    then
      autorefresh_stale_review(bufnr, expected)
      return "Cannot comment: review changed. Refresh and reopen the draft."
    end
    if vim.bo[bufnr].modified then
      return "Cannot comment: source buffer has unsaved changes."
    end
    local check = M._check_sync_state(expected.vcs_info, expected.rel_path, expected.review.head_sha)
    if not check.ok then
      return check.err
    end
    local target_error, prepared = validate_target(expected, anch)
    if target_error then
      return target_error
    end
    if provider_changed(bufnr, expected) then
      return "Cannot comment: provider context changed. Reopen the draft."
    end
    if not vim.api.nvim_buf_is_valid(bufnr) or vim.api.nvim_buf_get_changedtick(bufnr) ~= tick then
      return "Cannot comment: source buffer changed during validation. Retry after saving."
    end
    current = context_repository.get(bufnr)
    snapshot = review_repository.get(bufnr)
    if
      not current
      or not vim.deep_equal(current.vcs_info, expected.vcs_info)
      or not snapshot
      or not snapshot.review
      or not require("parley.provider").same_review(snapshot.review, expected.review)
      or current.rel_path ~= expected.rel_path
      or current.revision ~= expected.revision
    then
      autorefresh_stale_review(bufnr, expected)
      return "Cannot comment: review context changed during validation. Reopen the draft."
    end
    return nil, prepared
  end

  return { target = validate_target, submission = validate_submission, provider_changed = provider_changed }
end
