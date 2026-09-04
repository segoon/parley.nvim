--- Generic reaction presentation, availability, and picker context guards.
local providers = require("parley.repositories.provider")
local reviews = require("parley.repositories.review")
local M = {}

--- @param bufnr integer
--- @return table|nil
function M.context(bufnr)
  local provider = providers.get(bufnr)
  local review = reviews.get(bufnr)
  if provider and review and review.review then
    return { provider = provider.provider, review = review.review }
  end
end

--- Capture stable identity without copying the provider instance.
--- @param bufnr integer
--- @return table|nil
function M.capture(bufnr)
  local ctx = M.context(bufnr)
  if ctx then
    return { provider = ctx.provider, id = ctx.review.pr.id, head = ctx.review.head_sha }
  end
end

--- @param bufnr integer
--- @return fun(code: string): parley.ReactionPresentation
function M.presentation(bufnr)
  local snapshot = providers.get(bufnr)
  local ctx = M.context(bufnr)
  local provider = ctx and ctx.provider or snapshot and snapshot.provider
  return function(code)
    if provider and provider.reaction_presentation then
      local ok, value = pcall(provider.reaction_presentation, provider, code)
      if ok and type(value) == "table" and type(value.label) == "string" then
        return value
      end
    end
    return { label = code }
  end
end

--- @param provider parley.Provider
--- @param review parley.DetectedReview
--- @param comment parley.Comment
--- @return table[], string|nil
function M.items(provider, review, comment)
  local reason = "Reaction changes are unavailable for this provider"
  if not provider or not provider.reaction_choices then
    return {}, reason
  end
  local ok, choices, unavailable = pcall(provider.reaction_choices, provider, review, comment)
  if not ok or type(choices) ~= "table" then
    return {}, "Could not load reaction choices"
  end
  local counts, result, seen = {}, {}, {}
  for _, reaction in ipairs(comment.reactions or {}) do
    counts[reaction.type] = reaction
  end
  for _, choice in ipairs(choices) do
    if
      type(choice) ~= "table"
      or type(choice.reaction) ~= "string"
      or choice.reaction == ""
      or type(choice.label) ~= "string"
      or seen[choice.reaction]
    then
      return {}, "Invalid provider reaction choices"
    end
    seen[choice.reaction] = true
    local state = counts[choice.reaction] or {}
    result[#result + 1] = {
      reaction = choice.reaction,
      label = choice.label,
      emoji = choice.emoji,
      count = state.count or 0,
      viewer_reacted = state.viewer_reacted or false,
    }
  end
  return result, unavailable or reason
end

--- @param bufnr integer
--- @param comment parley.Comment
--- @param code string
--- @param expected? table
--- @return string|nil
function M.validate(bufnr, comment, code, expected)
  local ctx = M.context(bufnr)
  if not ctx then
    return "Parley review context is unavailable"
  end
  if
    expected
    and (ctx.provider ~= expected.provider or ctx.review.pr.id ~= expected.id or ctx.review.head_sha ~= expected.head)
  then
    return "Review context changed; reopen the reaction picker"
  end
  local items, reason = M.items(ctx.provider, ctx.review, comment)
  for _, item in ipairs(items) do
    if item.reaction == code then
      return nil
    end
  end
  return #items == 0 and reason or "This reaction is no longer available"
end

--- @param bufnr integer
--- @param line integer|nil
--- @param comment parley.Comment
--- @param picker fun(items: table[], callback: fun(item: table|nil))
--- @param notify fun(message: string, level: integer)
--- @return boolean
function M.select(bufnr, line, comment, picker, notify)
  local ctx, expected = M.context(bufnr), M.capture(bufnr)
  if not ctx then
    notify("Parley review context is unavailable", vim.log.levels.INFO)
    return false
  end
  local items, reason = M.items(ctx.provider, ctx.review, comment)
  if #items == 0 then
    notify(reason, vim.log.levels.INFO)
    return false
  end
  picker(items, function(item)
    if not item then
      return
    end
    local err = M.validate(bufnr, comment, item.reaction, expected)
    if err then
      notify(err, vim.log.levels.INFO)
      return
    end
    require("parley.services.write").react_comment(bufnr, line, comment, item.reaction, expected)
  end)
  return true
end
return M
