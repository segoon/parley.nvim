--- Select explicit provider review actions with confirmation before submission.
local contexts = require("parley.services.write_context")
local M = {}
--- @type fun(message: string): boolean
M._confirm = function(message)
  return vim.fn.confirm(message, "&Cancel\n&Submit", 1) == 2
end
--- @param bufnr integer
--- @return boolean
function M.run(bufnr)
  bufnr = require("parley.discussion_window").resolve_source_bufnr(bufnr)
  local write = require("parley.services.write")
  local reason = contexts.reason(bufnr, "review_action")
  if reason then
    write._notify(reason, vim.log.levels.INFO)
    return false
  end
  local ctx = contexts.get(bufnr)
  local provider = ctx.provider
  if not provider.review_actions or not provider.begin_review_action then
    write._notify("Explicit review actions are unavailable for this provider", vim.log.levels.INFO)
    return false
  end
  local ok, choices, unavailable = pcall(provider.review_actions, provider, ctx.review)
  if not ok or type(choices) ~= "table" or #choices == 0 then
    write._notify(unavailable or "Could not load review actions; refresh the review", vim.log.levels.INFO)
    return false
  end
  for _, choice in ipairs(choices) do
    if
      type(choice) ~= "table"
      or type(choice.action) ~= "string"
      or type(choice.label) ~= "string"
      or type(choice.confirmation) ~= "string"
    then
      write._notify("Invalid provider review actions", vim.log.levels.ERROR)
      return false
    end
  end
  local expected = {
    provider = provider,
    review = vim.deepcopy(ctx.review),
    identity = ctx.identity,
    identity_checked = ctx.identity_checked,
  }
  return require("parley.reaction_picker_window").open(choices, {
    prompt = "Review actions",
    source_winid = vim.api.nvim_get_current_win(),
    render_item = function(item)
      return item.label .. (item.reason and " — " .. item.reason or "")
    end,
  }, function(item)
    if not item then
      return
    end
    local changed = contexts.reason(bufnr, "review_action", expected)
    if changed or item.reason then
      write._notify(changed or item.reason, vim.log.levels.INFO)
      return
    end
    local message = item.label
      .. " PR #"
      .. expected.review.pr.id
      .. "?\nLoaded revision: "
      .. expected.review.head_sha
      .. "\n"
      .. item.confirmation
    if not M._confirm(message) then
      return
    end
    write.review_action(bufnr, item.action, expected)
  end)
end
return M
