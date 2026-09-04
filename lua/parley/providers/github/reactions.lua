local REACTION_EMOJI = {
  ["+1"] = "👍",
  ["-1"] = "👎",
  laugh = "😄",
  confused = "😕",
  heart = "❤️",
  hooray = "🎉",
  rocket = "🚀",
  eyes = "👀",
}

local REACTION_CHOICES = {
  { reaction = "+1", emoji = "👍", label = "+1" },
  { reaction = "-1", emoji = "👎", label = "-1" },
  { reaction = "laugh", emoji = "😄", label = "laugh" },
  { reaction = "confused", emoji = "😕", label = "confused" },
  { reaction = "heart", emoji = "❤️", label = "heart" },
  { reaction = "hooray", emoji = "🎉", label = "hooray" },
  { reaction = "rocket", emoji = "🚀", label = "rocket" },
  { reaction = "eyes", emoji = "👀", label = "eyes" },
}

local M = {}
--- @param self parley.Provider
--- @return parley.ReactionChoice[]
function M.choices(_self)
  return vim.deepcopy(REACTION_CHOICES)
end
--- @param self parley.Provider
--- @param code string
--- @return parley.ReactionPresentation
function M.presentation(_self, code)
  return { label = code, emoji = REACTION_EMOJI[code] }
end
--- @param code string
--- @return boolean
function M.supports(code)
  return REACTION_EMOJI[code] ~= nil
end
--- @return string[]
function M.keys()
  local result = {}
  for _, choice in ipairs(REACTION_CHOICES) do
    result[#result + 1] = choice.reaction
  end
  return result
end
return M
