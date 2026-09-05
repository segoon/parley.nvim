--- Explicit Arcanum review semantics. The server remains authoritative for permissions.
local transport = require("parley.providers.arcanum.transport")
local session = require("parley.providers.arcanum.session")
local M = {}
local verbs = { approve = true, approve_pr = true, block_merge = true }
local definitions = {
  {
    action = "ship",
    label = "Ship",
    route = "/ship?sticky=false",
    method = "PUT",
    detail = "Approve the active diff.",
  },
  {
    action = "sticky_ship",
    label = "Sticky ship",
    route = "/ship?sticky=true",
    method = "PUT",
    detail = "Approve this PR, including future diffs until withdrawn.",
  },
  { action = "unship", label = "Unship", route = "/ship", method = "DELETE", detail = "Withdraw your approval." },
  {
    action = "block_merge",
    label = "Block merge",
    route = "/block-merge",
    method = "PUT",
    detail = "Block merging this PR.",
  },
  {
    action = "unblock_merge",
    label = "Unblock merge",
    route = "/block-merge",
    method = "DELETE",
    detail = "Withdraw your merge block.",
  },
}

--- min_ships_required is the server's remaining count, despite its wire name.
--- @param data any
--- @return parley.ReviewStatus
function M.status(data)
  if
    type(data) ~= "table"
    or type(data.reviewers) ~= "table"
    or not vim.islist(data.reviewers)
    or type(data.min_ships_required) ~= "number"
    or data.min_ships_required < 0
    or data.min_ships_required == math.huge
    or data.min_ships_required % 1 ~= 0
  then
    return "unknown"
  end
  local blocked, seen = false, {}
  for _, reviewer in ipairs(data.reviewers) do
    if
      type(reviewer) ~= "table"
      or type(reviewer.user) ~= "table"
      or type(reviewer.user.name) ~= "string"
      or not reviewer.user.name:find("%S")
      or not verbs[reviewer.action]
      or seen[reviewer.user.name]
    then
      return "unknown"
    end
    seen[reviewer.user.name] = true
    blocked = blocked or reviewer.action == "block_merge"
  end
  return blocked and "changes_requested" or data.min_ships_required == 0 and "approved" or "pending"
end

--- @param self parley.arcanum.Provider
--- @param review parley.DetectedReview
function M.load(self, review)
  local ok, data = pcall(
    transport.http_run,
    self,
    "GET",
    "/v1/plugin/pull-request/" .. review.pr.id .. "/review?fields=reviewers(user(name),action),min_ships_required"
  )
  review.pr.review_status = ok and M.status(data) or "unknown"
  review.write_context.review_data = review.pr.review_status ~= "unknown" and data or nil
end

--- @param self parley.arcanum.Provider
--- @param review parley.DetectedReview
--- @return parley.ReviewActionChoice[], string|nil
function M.choices(self, review)
  local wc = review.write_context or {}
  if
    M.status(wc.review_data) == "unknown"
    or not require("parley.providers.arcanum.inline").valid_diff_id(wc.diff_id)
    or type(review.head_sha) ~= "string"
    or not review.head_sha:find("%S")
  then
    return {}, "Review status or active diff is unavailable; refresh the review"
  end
  local verdict = "none"
  for _, reviewer in ipairs(wc.review_data.reviewers) do
    if reviewer.user.name == self._viewer_login then
      verdict = reviewer.action
    end
  end
  local choices = vim.deepcopy(definitions)
  for _, choice in ipairs(choices) do
    choice.confirmation = choice.detail .. "\nYour current verdict: " .. verdict
    if choice.action == "unship" and verdict ~= "approve" and verdict ~= "approve_pr" then
      choice.reason = "You have no approval to withdraw"
    elseif choice.action == "unblock_merge" and verdict ~= "block_merge" then
      choice.reason = "You have no merge block to withdraw"
    end
  end
  return choices
end

--- Recheck immediately before mutation. The API cannot atomically pin the expected diff.
--- @param self parley.arcanum.Provider
--- @param review parley.DetectedReview
--- @param action string
--- @param callback parley.WriteCallback
--- @return parley.CancelHandle
function M.start(self, review, action, callback)
  local done, handle, generation = false, nil, 0
  local scope = "GENERIC_READ"
  --- @param result parley.WriteResult
  local function finish(result)
    if done then
      return
    end
    done = true
    callback(require("parley.providers.arcanum.action_result").explain(result, scope))
  end
  local cancel = {
    cancel = function()
      if done then
        return
      end
      if handle then
        handle.cancel()
      else
        finish({ ok = false, cancelled = true })
      end
    end,
  }
  local ok, err = pcall(session.require_verified, self)
  if not ok then
    finish({ ok = false, err = tostring(err) })
    return cancel
  end
  local choices, reason = M.choices(self, review)
  local selected
  for _, choice in ipairs(choices) do
    if choice.action == action then
      selected = choice
    end
  end
  if not selected or selected.reason then
    finish({ ok = false, err = selected and selected.reason or reason or "Unknown review action" })
    return cancel
  end
  local wc = review.write_context
  if not tostring(wc.pr_id):match("^%d+$") or tostring(wc.pr_id) ~= tostring(review.pr.id) then
    finish({ ok = false, err = "Review ID is unavailable; refresh the review" })
    return cancel
  end
  local token, host = self._token, self._host
  --- @param method string
  --- @param path string
  --- @param cb function
  local function request(method, path, cb)
    generation = generation + 1
    local current = generation
    local called = false
    local function receive(result)
      if called or done then
        return
      end
      called = true
      cb(result)
    end
    local h =
      transport.http_start(self, method, path, nil, receive, { retry_policy = method == "GET" and "read" or "none" })
    if current == generation then
      handle = h
    end
  end
  request("GET", "/v1/pull-requests/" .. wc.pr_id .. "/active-diff?fields=id,commit_ids(head)", function(result)
    if done then
      return
    end
    if not result.ok then
      finish(result)
      return
    end
    local diff = result.data
    if not session.current(self) or token ~= self._token or host ~= self._host then
      finish({ ok = false, err = "Arcanum credentials changed; refresh the review" })
      return
    end
    if
      type(diff) ~= "table"
      or diff.id ~= wc.diff_id
      or type(diff.commit_ids) ~= "table"
      or diff.commit_ids.head ~= review.head_sha
    then
      finish({ ok = false, err = "Active diff changed or is unavailable; refresh before reviewing" })
      return
    end
    scope = selected.method == "PUT" and "REVIEW_REQUEST_SHIP" or "GENERIC_WRITE"
    request(selected.method, "/v1/plugin/pull-request/" .. wc.pr_id .. "/review" .. selected.route, finish)
  end)
  return cancel
end
return M
