--- Command descriptors shared by completion and documentation checks.
local M = {}
--- @type table<string, string[]>
M.groups = {
  review = { "actions" },
  discussion = { "open", "close", "toggle", "new", "reply", "list", "resolve", "reopen", "view" },
  comment = { "react", "edit", "delete" },
  nav = { "buf-next", "buf-prev", "review-next", "review-prev" },
  diffview = { "open", "close", "toggle" },
}
--- @type string[]
M.top_level = { "discussion", "comment", "review", "nav", "quickfix", "refresh", "diffview", "view" }
--- @type table<string, parley.ProviderAction>
M.issue_actions = { resolve = "resolve", reopen = "unresolve" }
return M
