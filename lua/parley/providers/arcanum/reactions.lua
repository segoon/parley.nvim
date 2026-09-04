--- Arcanum codes remain opaque; mutation transport is not implemented.
local M = {}
--- @param self parley.Provider
--- @return parley.ReactionChoice[], string
function M.choices(_self)
  return {}, "Arcanum reaction changes are not implemented in Parley"
end
--- @param self parley.Provider
--- @param code string
--- @return parley.ReactionPresentation
function M.presentation(_self, code)
  return { label = code }
end
return M
