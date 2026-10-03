--- CLI command selection and one asynchronous attempt; lifecycle policy lives in transport.
local M = {}
--- @type fun(argv: string[], opts: table, callback: function): table
M._system = vim.system

--- @class parley.arcanum.Command
--- @field args string[]
--- @field stdin? string

--- Select only commands that preserve the requested operation's semantics.
--- Paths are provider-owned contracts, never arbitrary user input.
--- @param method string
--- @param path string
--- @param body? table
--- @param opts? parley.arcanum.RequestOptions
--- @return parley.arcanum.Command|nil
function M.request(method, path, body, opts)
  local route, fields = path:match("^([^?]+)%?fields=(.*)$")
  route = route or path
  body, opts = body or {}, opts or {}
  local args, content
  local pr = route:match("^/v1/pull%-requests/(%d+)$")
  local diff_pr = route:match("^/v1/pull%-requests/(%d+)/active%-diff$")
  local diff, action = route:match("^/v2/public/diff/(%d+)/(%a+)$")
  local comment, suffix = route:match("^/v1/public/review%-requests%-comments/(%-?%d+)(.*)$")
  local get_pr, get_comment = route:match("^/v2/public/pull%-request/(%d+)/comment/(%-?%d+)$")
  local reaction_pr, reaction_id, code = route:match("^/v1/plugin/pull%-request/(%d+)/comment/(%-?%d+)/reaction/(.*)$")
  if method == "POST" and route == "/v1/pull-requests/cursor" then
    args = {
      "pr",
      "list",
      "--from-branch",
      body.filter.user_branch_prefix,
      "--published",
      "true",
      "--desc",
      "--limit",
      tostring(body.limit),
      "--offset",
      tostring(body.offset),
    }
  elseif method == "GET" and (pr or diff_pr) then
    args = { "pr", diff_pr and "active-diff" or "get", "--id", diff_pr or pr }
  elseif method == "GET" and diff and action == "changelist" then
    args = { "pr", "changelist", "--diff-id", diff, "--diff-mode", "flat_path", "--ignorews=false" }
  elseif method == "POST" and diff and action == "comment" then
    args = {
      "comment",
      "post-diff",
      "--diff-id",
      diff,
      "--entry-id",
      body.entry_id,
      "--line",
      tostring(body.line),
      "--side",
      body.side,
      "--size",
      tostring(body.size),
    }
    content, fields = body.content, nil
  elseif comment and opts.pr_id then
    local verb = method == "POST" and suffix == "/replies" and "reply"
      or suffix == "" and (method == "PATCH" and "edit" or method == "DELETE" and "delete")
    if not verb then
      return nil
    end
    args = { "comment", verb, "--id", tostring(opts.pr_id), verb == "reply" and "--reply-to" or "--cid", comment }
    content, fields = body.content, nil
    if body.issue_status then
      vim.list_extend(args, { "--issue-status", body.issue_status })
    end
  elseif method == "GET" and get_pr then
    args = { "comment", "get", "--id", get_pr, "--cid", get_comment }
  elseif reaction_pr and (method == "PUT" or method == "DELETE") then
    code = code:gsub("%%(%x%x)", function(hex)
      return string.char(tonumber(hex, 16))
    end)
    if code == "." or code == ".." or not code:find("%S") then
      return nil
    end
    args = {
      "comment",
      method == "PUT" and "add-reaction" or "remove-reaction",
      "--id",
      reaction_pr,
      "--cid",
      reaction_id,
      "--code",
      code,
    }
  else
    return nil
  end
  if fields then
    vim.list_extend(args, { "--fields", fields })
  end
  if content == "" then
    args[#args + 1] = "--content="
  elseif content then
    vim.list_extend(args, { "--content-file", "/dev/stdin" })
  end
  return { args = args, stdin = content ~= "" and content or nil }
end

--- @param command parley.arcanum.Command
--- @param api_url string
--- @param token string
--- @param timeout integer
--- @param callback fun(result: table)
--- @return parley.CancelHandle
function M.start(command, api_url, token, timeout, callback)
  local argv = { "ya", "tool", "arcanum", "--json", "--api-url", api_url }
  vim.list_extend(argv, command.args)
  local done, process = false, nil
  --- @param result table
  local function finish(result)
    if done then
      return
    end
    done = true
    callback(result)
  end
  local ok = pcall(function()
    process = M._system(argv, {
      text = true,
      stdin = command.stdin,
      timeout = timeout,
      env = { ARC_TOKEN = token, ARCANUM_CLI_REVIEW_SYSTEM = "" },
    }, function(result)
      if result.code == 124 then
        finish({ ok = false, timed_out = true, uncertain = true, err = "Arcanum CLI request timed out" })
        return
      end
      local valid, data = pcall(vim.json.decode, result.stdout or "")
      if result.code == 0 and valid then
        finish({ ok = true, data = data })
        return
      end
      local failure = valid and type(data) == "table" and type(data.error) == "table" and data.error or {}
      local message = failure.message
        or (result.code == 0 and "Arcanum CLI returned invalid JSON")
        or "ya tool arcanum failed; check that the tool is installed and available"
      -- Never expose the selected credential, including in backend-provided errors.
      if token ~= "" then
        message = tostring(message):gsub(token:gsub("(%W)", "%%%1"), "[redacted]")
      end
      local status = failure.http_status
      finish({
        ok = false,
        err = message,
        status = status,
        retryable = status and require("parley.providers.arcanum.response").retry_status(status)
          or (not status and failure.code == "REMOTE_ERROR"),
        uncertain = status == nil or status >= 500,
      })
    end)
  end)
  if not ok then
    finish({ ok = false, sent = false, err = "Cannot start ya tool arcanum; check that ya is installed" })
  end
  return {
    cancel = function()
      if done then
        return
      end
      finish({ ok = false, cancelled = true })
      if process then
        pcall(process.kill, process, 9)
      end
    end,
  }
end
return M
