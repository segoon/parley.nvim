--- Recover PR ownership from an immutable diff before starting a comment operation.
local requests = require("parley.providers.arcanum.requests")
local transport = require("parley.providers.arcanum.transport")
local session = require("parley.providers.arcanum.session")
local await = require("parley.runtime.await")
local M = {}

--- @param review parley.DetectedReview
--- @return integer|string|nil
function M.pr_id(review)
  return review.write_context and review.write_context.pr_id or review.pr and review.pr.id
end

--- @param value any
--- @return boolean
local function valid_id(value)
  local number = type(value) == "number" and value
    or type(value) == "string" and value:match("^%d+$") and tonumber(value)
  return type(number) == "number" and number > 0 and number < math.huge and number == math.floor(number)
end

--- @alias parley.arcanum.CommentExecutor fun(owner: table, request: parley.arcanum.Request, receive: function): table

--- @param self parley.arcanum.Provider
--- @param review parley.DetectedReview
--- @param build fun(pr_id: integer|string|nil): parley.arcanum.Request
--- @param callback fun(result: table)
--- @param executor? parley.arcanum.CommentExecutor
--- @return parley.CancelHandle
function M.start(self, review, build, callback, executor)
  local done, generation, active = false, 0, nil
  local token, host, viewer = self._session_token, self._host, self._viewer_login
  executor = executor or transport.request_start
  --- @param result table
  local function finish(result)
    if done then
      return
    end
    done = true
    callback(result)
  end
  --- @param descriptor parley.arcanum.Request
  --- @param starter function
  --- @param receive function
  local function request(descriptor, starter, receive)
    generation = generation + 1
    local stage, delivered = generation, false
    local ok, handle = pcall(starter, self, descriptor, function(result)
      if done or delivered or stage ~= generation then
        return
      end
      delivered, active = true, nil
      receive(result)
    end)
    if not ok then
      finish({ ok = false, err = tostring(handle) })
    elseif not done and not delivered and stage == generation then
      active = handle
    elseif done and not delivered and handle then
      pcall(handle.cancel)
    end
  end
  --- @param pr_id integer|string|nil
  local function execute(pr_id)
    local current, err = pcall(session.require_current, self)
    if not current then
      finish({ ok = false, err = tostring(err) })
      return
    end
    if self._session_token ~= token or self._host ~= host or self._viewer_login ~= viewer then
      finish({ ok = false, err = "Arcanum session changed during comment scope lookup; refresh the review" })
      return
    end
    local ok, descriptor = pcall(build, pr_id)
    if not ok then
      finish({ ok = false, err = tostring(descriptor) })
      return
    end
    request(descriptor, executor, finish)
  end
  local pr_id = M.pr_id(review)
  local diff_id = review.write_context and review.write_context.diff_id
  if pr_id == nil and diff_id ~= nil then
    if type(diff_id) ~= "number" or not valid_id(diff_id) then
      finish({ ok = false, err = "Comment diff identity is invalid; refresh the review" })
    else
      request(requests.get_diff_info(diff_id), transport.request_start, function(result)
        if not result.ok then
          finish(result)
          return
        end
        local data = result.data
        if
          type(data) ~= "table"
          or data.id ~= diff_id
          or not valid_id(data.pull_request_id)
          or not review.write_context
          or review.write_context.diff_id ~= diff_id
          or (M.pr_id(review) ~= nil and tostring(M.pr_id(review)) ~= tostring(data.pull_request_id))
        then
          finish({ ok = false, err = "Cannot identify the comment's PR from its diff; refresh the review" })
          return
        end
        execute(data.pull_request_id)
      end)
    end
  elseif pr_id ~= nil and not valid_id(pr_id) then
    finish({ ok = false, err = "Comment PR identity is invalid; refresh the review" })
  else
    -- Preserve direct-provider behavior when neither PR nor diff scope is supplied.
    execute(pr_id)
  end
  return {
    cancel = function()
      if done then
        return
      end
      if active then
        pcall(active.cancel)
      end
      finish({ ok = false, cancelled = true })
    end,
  }
end

--- @param self parley.arcanum.Provider
--- @param review parley.DetectedReview
--- @param build fun(pr_id: integer|string|nil): parley.arcanum.Request
--- @return table|nil
function M.run(self, review, build)
  local result = await.callback(function(callback)
    M.start(self, review, build, callback)
  end)
  if not result.ok then
    error(result.err or "Arcanum comment operation failed", 0)
  end
  return result.data
end
return M
