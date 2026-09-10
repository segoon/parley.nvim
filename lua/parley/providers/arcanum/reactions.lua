--- PR-scoped reactions support inline, general, and historical comments alike.
local transport = require("parley.providers.arcanum.transport")
local M = {}
local palette = {
  { reaction = ":+1:", label = "Thumbs up", emoji = "👍" },
  { reaction = ":-1:", label = "Thumbs down", emoji = "👎" },
  { reaction = ":heart:", label = "Heart", emoji = "❤️" },
}
--- @param _self parley.Provider
--- @param code string
--- @return parley.ReactionPresentation
function M.presentation(_self, code)
  for _, choice in ipairs(palette) do
    if choice.reaction == code then
      return { label = choice.label, emoji = choice.emoji }
    end
  end
  return { label = code }
end
--- @param self parley.Provider
--- @param _review parley.DetectedReview
--- @param comment parley.Comment
--- @return parley.ReactionChoice[]
function M.choices(self, _review, comment)
  local choices, known = vim.deepcopy(palette), {}
  for _, choice in ipairs(choices) do
    known[choice.reaction] = true
  end
  for _, reaction in ipairs(comment.reactions or {}) do
    if reaction.viewer_reacted and not known[reaction.type] then
      known[reaction.type] = true
      choices[#choices + 1] = {
        reaction = reaction.type,
        label = "Remove " .. M.presentation(self, reaction.type).label,
        remove_only = true,
      }
    end
  end
  return choices
end
--- @param value string
--- @return string
local function encode(value)
  return (value:gsub("[^%w%-._~]", function(char)
    return string.format("%%%02X", char:byte())
  end))
end
--- @param self parley.arcanum.Provider
--- @param review parley.DetectedReview
--- @param id string
--- @param code string
--- @param present boolean
--- @param callback parley.WriteCallback
--- @return parley.CancelHandle
function M.start(self, review, id, code, present, callback)
  local ok, err = pcall(function()
    require("parley.providers.arcanum.session").require_verified(self)
    assert(type(id) == "string" and id:match("^%-?%d+$"), "Invalid Arcanum comment ID")
    assert(tostring(review.pr.id):match("^%d+$"), "Invalid Arcanum review ID")
    assert(type(code) == "string" and code ~= "" and type(present) == "boolean", "Invalid reaction")
    if present then
      local known = false
      for _, choice in ipairs(palette) do
        known = known or code == choice.reaction
      end
      assert(known, "This reaction can only be removed")
    end
  end)
  if not ok then
    callback({ ok = false, err = tostring(err) })
    return { cancel = function() end }
  end
  return transport.http_start(
    self,
    present and "PUT" or "DELETE",
    "/v1/plugin/pull-request/" .. review.pr.id .. "/comment/" .. id .. "/reaction/" .. encode(code),
    nil,
    function(result)
      if not result.ok and result.status == 409 then
        result.err = "AI comments allow one reaction per account. Refresh and remove yours before choosing another."
        result.refresh = true
      end
      callback(require("parley.providers.arcanum.action_result").explain(result, "GENERIC_WRITE"))
    end,
    { retry_policy = "none" }
  )
end
--- Legacy coroutine toggle reads fresh state before choosing an explicit mutation.
--- @param self parley.arcanum.Provider
--- @param review parley.DetectedReview
--- @param id string
--- @param code string
function M.run(self, review, id, code)
  assert(type(id) == "string" and id:match("^%-?%d+$"), "Invalid Arcanum comment ID")
  local comment
  for _, discussion in ipairs(self:fetch_discussions(review)) do
    for _, candidate in ipairs(discussion.comments) do
      if candidate.id == id then
        comment = candidate
      end
    end
  end
  assert(comment, "Comment is no longer available; refresh the review")
  local present = true
  for _, reaction in ipairs(comment.reactions or {}) do
    if reaction.type == code and reaction.viewer_reacted then
      present = false
    end
  end
  local result = require("parley.runtime.await").callback(function(cb)
    M.start(self, review, id, code, present, cb)
  end)
  if not result.ok then
    error(result.err or "Arcanum reaction update failed", 0)
  end
end
return M
