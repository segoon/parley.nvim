--- Explain authorization failures without displaying server response content.
local M = {}
--- @param result parley.WriteResult|table
--- @param scope string
--- @return parley.WriteResult
function M.explain(result, scope)
  if not result.ok then
    if result.status == 401 then
      result.err = "Arcanum authentication failed (401); check your token and refresh the review"
    elseif result.status == 403 then
      result.err = "Arcanum denied this action (403). It requires "
        .. scope
        .. "; account and review permissions may also restrict it. Check access and refresh."
    end
  end
  return result
end
return M
