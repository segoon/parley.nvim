--- V2 inline creation: one cancellable operation for callback and coroutine callers.
local transport = require("parley.providers.arcanum.transport")
local mapping = require("parley.providers.arcanum.mapping")
local ui = require("parley.runtime.ui")
local M = {}

local COMMENT_FIELDS = "id,author(name),content,reply_to_id,created_at,updated_at,edited_at,reactions(code,user(name))"

--- @param value any
--- @return boolean
local function nonempty(value)
  return type(value) == "string" and value:find("%S") ~= nil
end

--- @param value any
--- @return boolean
function M.valid_diff_id(value)
  return type(value) == "number" and value > 0 and value < math.huge and value == math.floor(value)
end

--- @param review parley.DetectedReview
--- @param file string
--- @param anchor parley.Anchor
--- @return string|nil
local function validate(review, file, anchor)
  local context = type(review) == "table" and review.write_context
  if type(context) ~= "table" or not M.valid_diff_id(context.diff_id) or not nonempty(review.head_sha) then
    return "Cannot comment: review diff or revision is unavailable. Refresh the review and reopen the draft."
  end
  if
    not nonempty(file)
    or type(anchor) ~= "table"
    or not M.valid_diff_id(anchor.start_line)
    or (anchor.end_line ~= nil and (not M.valid_diff_id(anchor.end_line) or anchor.end_line < anchor.start_line))
  then
    return "Cannot comment: invalid file or line range. Reopen the draft on the intended lines."
  end
end

--- Validate and map the V2 creation result without accepting placeholder identities.
--- @param raw any
--- @param viewer string
--- @return parley.Comment
local function map_created(raw, viewer)
  if
    type(raw) ~= "table"
    or not tostring(raw.id):match("^%-?%d+$")
    or type(raw.author) ~= "table"
    or not nonempty(raw.author.name)
    or type(raw.content) ~= "string"
    or not nonempty(raw.created_at)
  then
    error(
      "Arcanum returned an incomplete comment response. "
        .. "Check the review before retrying; the comment may have been sent.",
      0
    )
  end
  return mapping.map_comment(raw, viewer)
end

--- @param self parley.arcanum.Provider
--- @param review parley.DetectedReview
--- @param file string
--- @param anchor parley.Anchor
--- @param body parley.Body
--- @param callback parley.WriteCallback
--- @return parley.CancelHandle
function M.start(self, review, file, anchor, body, callback)
  local completed, generation = false, 0
  --- @type parley.CancelHandle|nil
  local active
  --- @param result table
  local function finish(result)
    if completed then
      return
    end
    completed = true
    ui.dispatch(function()
      callback(result)
    end)
  end
  local handle = {
    cancel = function()
      if completed then
        return
      end
      local request = active
      if request then
        pcall(request.cancel)
      end
      finish({ ok = false, cancelled = true })
    end,
  }

  --- Start a stage safely even when the transport invokes its callback inline.
  --- @param method string
  --- @param path string
  --- @param payload table|nil
  --- @param next_stage fun(data: any)
  local function request(method, path, payload, next_stage)
    if completed then
      return
    end
    generation = generation + 1
    local stage, delivered = generation, false
    active = nil
    local ok, result = pcall(transport.http_start, self, method, path, payload, function(response)
      if completed or delivered or generation ~= stage then
        return
      end
      delivered = true
      active = nil
      if not response.ok then
        finish(response)
        return
      end
      local success, err = pcall(next_stage, response.data)
      if not success then
        finish({ ok = false, err = tostring(err), uncertain = method == "POST" })
      end
    end, method == "POST" and { retry_policy = "create" } or nil)
    if not ok then
      finish({ ok = false, err = tostring(result) })
    elseif not completed and not delivered and generation == stage then
      active = result
    end
  end

  -- Preparation never awaits coroutine-only I/O.
  ui.dispatch(function()
    local err = validate(review, file, anchor)
    if err then
      finish({ ok = false, err = err })
      return
    end
    local ok, auth_err = pcall(require("parley.providers.arcanum.session").require_verified, self)
    if not ok then
      finish({ ok = false, err = tostring(auth_err) })
      return
    end
    local context = review.write_context
    local diff_id = context.diff_id
    local payload = {
      content = body.text,
      line = anchor.start_line,
      size = (anchor.end_line or anchor.start_line) - anchor.start_line + 1,
      side = "new",
      is_draft = false,
      is_issue = false,
    }
    --- @param entry_id string
    local function post(entry_id)
      payload.entry_id = entry_id
      request(
        "POST",
        "/v2/public/diff/" .. tostring(diff_id) .. "/comment?fields=" .. COMMENT_FIELDS,
        payload,
        function(raw)
          finish({ ok = true, comment = map_created(raw, self._viewer_login or "") })
        end
      )
    end
    local cached = context.changelist_diff_id == diff_id
      and type(context.changelist) == "table"
      and context.changelist[file]
    if nonempty(cached) then
      post(cached)
      return
    end
    request("GET", "/v2/public/diff/" .. tostring(diff_id) .. "/changelist?fields=path,entry_id", nil, function(data)
      local entries = {}
      if type(data) == "table" then
        for _, entry in ipairs(data) do
          if type(entry) == "table" and nonempty(entry.path) and nonempty(entry.entry_id) then
            entries[entry.path] = entry.entry_id
          end
        end
      end
      if not entries[file] then
        error(
          "Cannot comment: no inline entry for '"
            .. file
            .. "' in the loaded diff. Refresh the review and reopen the draft.",
          0
        )
      end
      if context.diff_id == diff_id then
        context.changelist, context.changelist_diff_id = entries, diff_id
      end
      post(entries[file])
    end)
  end)
  return handle
end

--- @param self parley.arcanum.Provider
--- @param review parley.DetectedReview
--- @param file string
--- @param anchor parley.Anchor
--- @param body parley.Body
--- @return parley.Comment
function M.run(self, review, file, anchor, body)
  local result = require("parley.runtime.await").callback(function(callback)
    M.start(self, review, file, anchor, body, callback)
  end)
  if not result.ok then
    error(result.err or "Arcanum comment cancelled", 0)
  end
  return result.comment
end

return M
