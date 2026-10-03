--- Acknowledged writes may need a read; failure of that read must never replay the write.
local transport = require("parley.providers.arcanum.transport")
local mapping = require("parley.providers.arcanum.mapping")
local M = {}
local fields = "id,author(name),content,reply_to_id,created_at,updated_at,edited_at,reactions(code,user(name))"

--- @param review parley.DetectedReview
--- @return integer|string|nil
function M.pr_id(review)
  return review.write_context and review.write_context.pr_id or review.pr and review.pr.id
end

--- @param raw any
--- @param viewer string
--- @param body table
--- @return parley.Comment|nil
local function mapped(raw, viewer, body)
  if type(raw) ~= "table" or not tostring(raw.id):match("^%-?%d+$") or tonumber(raw.id) == 0 then
    return nil
  end
  local author = type(raw.author) == "table" and raw.author or type(raw.user) == "table" and raw.user or {}
  if raw.content == nil and body.content == "" then
    raw.content = ""
  end
  if
    type(raw.content) ~= "string"
    or type(author.name) ~= "string"
    or not author.name:find("%S")
    or type(raw.created_at) ~= "string"
    or raw.created_at == ""
  then
    return nil
  end
  local ok, comment = pcall(mapping.map_comment, raw, viewer)
  return ok and comment or nil
end

--- @param self parley.arcanum.Provider
--- @param method string
--- @param path string
--- @param body table
--- @param callback parley.WriteCallback
--- @param opts? parley.arcanum.RequestOptions
--- @return parley.CancelHandle
function M.start(self, method, path, body, callback, opts)
  local done, acknowledged, active, generation = false, false, nil, 0
  opts = opts or {}
  --- @param result parley.WriteResult
  local function finish(result)
    if done then
      return
    end
    done = true
    callback(result)
  end
  --- @param verb string
  --- @param route string
  --- @param payload table|nil
  --- @param options table|nil
  --- @param receive fun(result: table)
  local function request(verb, route, payload, options, receive)
    generation = generation + 1
    local stage, delivered = generation, false
    local ok, handle = pcall(transport.request_start, self, verb, route, payload, function(result)
      if done or delivered or stage ~= generation then
        return
      end
      delivered, active = true, nil
      receive(result)
    end, options)
    if not ok then
      finish(acknowledged and { ok = true } or { ok = false, err = tostring(handle) })
    elseif not done and not delivered and stage == generation then
      active = handle
    end
  end
  request(method, path, body, opts, function(result)
    if not result.ok then
      finish(result)
      return
    end
    acknowledged = true
    local comment = mapped(result.data, self._viewer_login or "", body)
    if comment then
      finish({ ok = true, comment = comment })
      return
    end
    local id = type(result.data) == "table" and result.data.id
    if not id and method == "PATCH" then
      id = path:match("/(%-?%d+)$")
    end
    if not opts.pr_id or not tostring(id):match("^%-?%d+$") or tonumber(id) == 0 then
      finish({ ok = true })
      return
    end
    request(
      "GET",
      "/v2/public/pull-request/" .. opts.pr_id .. "/comment/" .. id .. "?fields=" .. fields,
      nil,
      nil,
      function(read)
        finish({ ok = true, comment = read.ok and mapped(read.data, self._viewer_login or "", body) or nil })
      end
    )
  end)
  return {
    cancel = function()
      if done then
        return
      end
      local handle = active
      if acknowledged then
        finish({ ok = true })
      end
      if handle then
        pcall(handle.cancel)
      end
      finish({ ok = false, cancelled = true })
    end,
  }
end
return M
