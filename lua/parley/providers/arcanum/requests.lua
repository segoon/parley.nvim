--- Provider-owned operation builders. Executor selection happens before sending.
local M = {}

--- @class parley.arcanum.RequestContext
--- @field operation string
--- @field retry_policy 'read'|'create'|'none'
--- @field pr_id? integer|string PR scope for comment hydration.
--- @field comment_id? string Existing comment ID for sparse edit acknowledgements.
--- @field content? string Submitted text, including an explicitly empty edit.

--- @class parley.arcanum.CliRequest : parley.arcanum.RequestContext, parley.arcanum.Command
--- @field kind 'cli'

--- @class parley.arcanum.HttpRequest : parley.arcanum.RequestContext
--- @field kind 'http'
--- @field method string
--- @field path string Relative API path, including any field projection.
--- @field body? table HTTP payload.

--- @alias parley.arcanum.Request parley.arcanum.CliRequest|parley.arcanum.HttpRequest

local comment_fields = "id,author(name),content,reply_to_id,created_at,updated_at,edited_at,reactions(code,user(name))"

--- @param operation string
--- @param policy 'read'|'create'|'none'
--- @param args string[]
--- @param content? string
--- @return parley.arcanum.CliRequest
local function cli(operation, policy, args, content)
  local request = { kind = "cli", operation = operation, retry_policy = policy, args = args }
  if content == "" then
    args[#args + 1] = "--content="
  elseif content then
    vim.list_extend(args, { "--content-file", "/dev/stdin" })
    request.stdin = content
  end
  return request
end

--- @param operation string
--- @param policy 'read'|'create'|'none'
--- @param method string
--- @param path string
--- @param body? table
--- @return parley.arcanum.HttpRequest
local function http(operation, policy, method, path, body)
  return { kind = "http", operation = operation, retry_policy = policy, method = method, path = path, body = body }
end

--- @param request parley.arcanum.Request
--- @param pr_id? integer|string
--- @param comment_id? string
--- @param content string
--- @return parley.arcanum.Request
local function comment(request, pr_id, comment_id, content)
  request.pr_id, request.comment_id, request.content = pr_id, comment_id, content
  return request
end

--- @param branch string
--- @param offset integer
--- @return parley.arcanum.Request
function M.search_prs(branch, offset)
  return cli("search_prs", "read", {
    "pr",
    "list",
    "--from-branch",
    branch,
    "--published",
    "true",
    "--desc",
    "--limit",
    "100",
    "--offset",
    tostring(offset),
    "--fields",
    "id,vcs(from_branch)",
  })
end

--- @param pr_id integer|string
--- @return parley.arcanum.Request
function M.get_pr(pr_id)
  return cli("get_pr", "read", { "pr", "get", "--id", tostring(pr_id), "--fields", "id,summary,status,url,author,vcs" })
end

--- @param pr_id integer|string
--- @return parley.arcanum.Request
function M.get_active_diff(pr_id)
  return cli(
    "get_active_diff",
    "read",
    { "pr", "active-diff", "--id", tostring(pr_id), "--fields", "id,commit_ids(base,head,merge)" }
  )
end

--- @param diff_id integer
--- @return parley.arcanum.Request
function M.get_changelist(diff_id)
  return cli("get_changelist", "read", {
    "pr",
    "changelist",
    "--diff-id",
    tostring(diff_id),
    "--diff-mode",
    "flat_path",
    "--ignorews=false",
    "--fields",
    "path,entry_id",
  })
end

--- @param pr_id integer|string
--- @param id string
--- @return parley.arcanum.Request
function M.get_comment(pr_id, id)
  return cli(
    "get_comment",
    "read",
    { "comment", "get", "--id", tostring(pr_id), "--cid", id, "--fields", comment_fields }
  )
end

--- @param pr_id? integer|string
--- @param diff_id integer
--- @param body table
--- @param keyed boolean
--- @return parley.arcanum.Request
function M.create_inline(pr_id, diff_id, body, keyed)
  local request
  if keyed then
    request = http(
      "create_inline",
      "create",
      "POST",
      "/v2/public/diff/" .. diff_id .. "/comment?fields=" .. comment_fields,
      body
    )
  else
    request = cli("create_inline", "create", {
      "comment",
      "post-diff",
      "--diff-id",
      tostring(diff_id),
      "--entry-id",
      body.entry_id,
      "--line",
      tostring(body.line),
      "--side",
      body.side,
      "--size",
      tostring(body.size),
    }, body.content)
  end
  return comment(request, pr_id, nil, body.content)
end

--- @param pr_id? integer|string
--- @param id string
--- @param content string
--- @param keyed boolean
--- @return parley.arcanum.Request
function M.reply(pr_id, id, content, keyed)
  local request
  -- A missing PR scope retains the existing direct-provider HTTP behavior.
  if keyed or not pr_id then
    request =
      http("reply", "create", "POST", "/v1/public/review-requests-comments/" .. id .. "/replies", { content = content })
  else
    request = cli("reply", "create", { "comment", "reply", "--id", tostring(pr_id), "--reply-to", id }, content)
  end
  return comment(request, pr_id, nil, content)
end

--- @param pr_id? integer|string
--- @param id string
--- @param content string
--- @return parley.arcanum.Request
function M.edit_comment(pr_id, id, content)
  local request = pr_id
      and cli("edit_comment", "none", { "comment", "edit", "--id", tostring(pr_id), "--cid", id }, content)
    or http("edit_comment", "none", "PATCH", "/v1/public/review-requests-comments/" .. id, { content = content })
  return comment(request, pr_id, id, content)
end

--- @param pr_id? integer|string
--- @param id string
--- @return parley.arcanum.Request
function M.delete_comment(pr_id, id)
  return pr_id and cli("delete_comment", "none", { "comment", "delete", "--id", tostring(pr_id), "--cid", id })
    or http("delete_comment", "none", "DELETE", "/v1/public/review-requests-comments/" .. id)
end

--- @param pr_id? integer|string
--- @param id string
--- @param state 'open'|'resolved'
--- @return parley.arcanum.Request
function M.set_issue_state(pr_id, id, state)
  return pr_id
      and cli(
        "set_issue_state",
        "none",
        { "comment", "edit", "--id", tostring(pr_id), "--cid", id, "--issue-status", state }
      )
    or http("set_issue_state", "none", "PATCH", "/v1/public/review-requests-comments/" .. id, { issue_status = state })
end

--- @param pr_id integer|string
--- @param id string
--- @param code string
--- @param present boolean
--- @return parley.arcanum.Request
function M.set_reaction(pr_id, id, code, present)
  if code ~= "." and code ~= ".." and code:find("%S") then
    return cli("set_reaction", "none", {
      "comment",
      present and "add-reaction" or "remove-reaction",
      "--id",
      tostring(pr_id),
      "--cid",
      id,
      "--code",
      code,
    })
  end
  local encoded = code:gsub("[^%w%-._~]", function(char)
    return string.format("%%%02X", char:byte())
  end)
  return http(
    "set_reaction",
    "none",
    present and "PUT" or "DELETE",
    "/v1/plugin/pull-request/" .. pr_id .. "/comment/" .. id .. "/reaction/" .. encoded
  )
end

--- @param pr_id integer|string
--- @return parley.arcanum.Request
function M.get_discussions(pr_id)
  return http("get_discussions", "read", "GET", "/v1/public/review-requests/" .. pr_id .. "/comments")
end

--- @param pr_id integer|string
--- @return parley.arcanum.Request
function M.get_review(pr_id)
  return http(
    "get_review",
    "read",
    "GET",
    "/v1/plugin/pull-request/" .. pr_id .. "/review?fields=reviewers(user(name),action),min_ships_required"
  )
end

local verdicts = {
  ship = { "PUT", "/ship?sticky=false" },
  sticky_ship = { "PUT", "/ship?sticky=true" },
  unship = { "DELETE", "/ship" },
  block_merge = { "PUT", "/block-merge" },
  unblock_merge = { "DELETE", "/block-merge" },
}

--- @param pr_id integer|string
--- @param action string
--- @return parley.arcanum.Request
function M.apply_review_action(pr_id, action)
  local verdict = assert(verdicts[action], "Unknown Arcanum review action")
  return http("apply_review_action", "none", verdict[1], "/v1/plugin/pull-request/" .. pr_id .. "/review" .. verdict[2])
end

return M
