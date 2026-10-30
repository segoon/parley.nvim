--- One asynchronous CLI attempt; command construction lives in requests, lifecycle policy in transport.
local M = {}
--- @type fun(argv: string[], opts: table, callback: function): table
M._system = vim.system

--- @class parley.arcanum.Command
--- @field args string[]
--- @field stdin? string

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
