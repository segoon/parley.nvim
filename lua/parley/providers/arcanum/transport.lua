--- Arcanum transport: one lifecycle for CLI and retained HTTP operations.
local http = require("parley.http")
local ui = require("parley.runtime.ui")
local await = require("parley.runtime.await")
local scheduler = require("parley.providers.arcanum.scheduler")
local response = require("parley.providers.arcanum.response")
local dbg = require("parley.debug")
local M = {}

--- @class parley.arcanum.RequestOptions
--- @field pr_id? integer|string PR scope for signed comment operations.
--- @field retry_policy? 'read'|'create'|'none' GET/HEAD default to read; all other methods default to none.
--- @class parley.arcanum.TransportResult
--- @field ok boolean
--- @field data? table
--- @field status? integer
--- @field err? string
--- @field cancelled? boolean
--- @field timed_out? boolean
--- @field sent boolean
--- @field uncertain? boolean A mutation may have succeeded despite this failure.

--- @type fun(): number
M._wall_time = os.time
--- @type fun(): string Opaque per-operation key, independent of credentials or payload.
M._key = function()
  local bytes = assert((vim.uv or vim.loop).random(16))
  return (bytes:gsub(".", function(char)
    return string.format("%02x", string.byte(char))
  end))
end

--- @param self parley.arcanum.Provider
--- @param path string
--- @return string
function M.api_url(self, path)
  return "https://" .. self._host .. "/api" .. path
end

--- @param self parley.arcanum.Provider
--- @param method string
--- @param path string
--- @param body table|nil
--- @param callback fun(result: parley.arcanum.TransportResult)
--- @param opts? parley.arcanum.RequestOptions
--- @return parley.CancelHandle
function M.request_start(self, method, path, body, callback, opts)
  local created = scheduler._now()
  local session_token, host, viewer = self._session_token, self._host, self._viewer_login
  local done, sent, uncertain, in_flight = false, false, false, false
  method = method:upper()
  local active, queued, deadline_timer
  local attempt, generation = 0, 0
  local policy = opts and opts.retry_policy or ((method == "GET" or method == "HEAD") and "read" or "none")
  local mutation = policy ~= "read"

  --- @param result table
  local function finish(result)
    if done then
      return
    end
    if
      session_token
      and (
        self._session_token ~= session_token
        or self._viewer_login ~= viewer
        or self._host ~= host
        or not require("parley.providers.arcanum.session").current(self)
      )
    then
      result.ok, result.data = false, nil
      result.err = "Arcanum credentials changed; refresh the review"
      uncertain = mutation and sent
    end
    done = true
    dbg.trace(
      "arcanum.transport",
      "complete: attempts="
        .. attempt
        .. " sent="
        .. tostring(sent)
        .. " ok="
        .. tostring(result.ok)
        .. " cancelled="
        .. tostring(result.cancelled or false)
        .. " timed_out="
        .. tostring(result.timed_out or false)
    )
    result.sent = sent
    result.uncertain = not result.ok and mutation and (uncertain or (sent and result.cancelled)) or false
    if result.uncertain then
      result.err = (result.err or "Arcanum request cancelled.")
        .. " Check the review before retrying; the change may have been sent."
    end
    scheduler.close_timer(deadline_timer)
    local request, entry = active, queued
    active, queued = nil, nil
    if entry then
      pcall(entry.cancel)
    end
    if request then
      pcall(request.cancel)
    end
    ui.dispatch(function()
      callback(result)
    end)
  end
  local handle = {
    cancel = function()
      finish({
        ok = false,
        cancelled = true,
        err = sent and "Arcanum request cancelled." or "Cancelled before sending.",
      })
    end,
  }

  local ok, err = pcall(function()
    local cfg = require("parley.providers.arcanum.config").resolve(self._config)
    assert(policy == "read" or policy == "create" or policy == "none", "Invalid Arcanum retry policy")
    local deadline = created + cfg.timeout_ms
    local url = M.api_url(self, path)
    local headers = {
      Authorization = "OAuth " .. (self._token or ""),
      ["Content-Type"] = "application/json",
      Accept = "application/json",
    }
    local serialized = body and vim.json.encode(body) or nil
    local command = not (policy == "create" and cfg.idempotent_write_retries)
        and require("parley.providers.arcanum.cli").request(method, path, body, opts)
      or nil
    if policy == "create" and not command then
      headers["Idempotency-Key"] = M._key()
    end
    local can_retry = policy == "read" or (policy == "create" and not command and cfg.idempotent_write_retries)
    --- @param remaining integer
    --- @param receive fun(result: table)
    --- @return parley.CancelHandle
    local function start_attempt(remaining, receive)
      if command then
        return require("parley.providers.arcanum.cli").start(
          command,
          M.api_url(self, ""),
          self._token or "",
          remaining,
          receive
        )
      end
      return http.start(
        { url = url, method = method, headers = vim.deepcopy(headers), body = serialized, timeout_ms = remaining },
        function(result)
          if not result.ok then
            receive({
              ok = false,
              err = result.err,
              cancelled = result.cancelled,
              sent = result.sent,
              uncertain = result.sent ~= false,
              retryable = response.retry_exit(result.exit),
            })
            return
          end
          local raw = result.response
          local valid, data = pcall(response.unwrap, raw)
          receive({
            ok = raw.ok and valid,
            data = valid and data or nil,
            err = not valid and tostring(data) or (not raw.ok and ("Arcanum HTTP " .. raw.status) or nil),
            status = raw.status,
            retryable = not raw.ok and response.retry_status(raw.status),
            retry_after = raw.status == 429 and response.retry_after(raw.headers, M._wall_time()) or nil,
            uncertain = raw.status >= 500 or (raw.ok and not valid),
          })
        end
      )
    end
    local queue = scheduler.scope(self._host, self._token or "", cfg.request_interval_ms)
    deadline_timer = scheduler._defer(function()
      ui.dispatch(function()
        if sent and mutation and in_flight then
          uncertain = true
        end
        finish({ ok = false, timed_out = true, err = "Arcanum request timed out (including queue and retry waits)." })
      end)
    end, math.max(0, math.ceil(deadline - scheduler._now())))
    if done then
      scheduler.close_timer(deadline_timer)
      return
    end

    --- @param delay number
    local enqueue
    --- @param retryable boolean
    --- @param message string
    --- @param delay number
    --- @param status? integer
    local function fail_or_retry(retryable, message, delay, status)
      if can_retry and retryable and attempt <= cfg.retry_count then
        enqueue(delay)
      else
        finish({ ok = false, err = message, status = status })
      end
    end
    enqueue = function(delay)
      if done then
        return
      end
      dbg.trace("arcanum.transport", "queued: retry_wait_ms=" .. delay)
      local began = false
      local entry = scheduler.enqueue(queue, scheduler._now() + delay, function()
        began = true
        queued = nil
        if done then
          return
        end
        if
          session_token
          and (
            self._session_token ~= session_token
            or self._viewer_login ~= viewer
            or self._host ~= host
            or not require("parley.providers.arcanum.session").current(self)
          )
        then
          finish({ ok = false, err = "Arcanum credentials changed before sending; refresh the review" })
          return
        end
        local remaining = deadline - scheduler._now()
        if remaining <= 0 then
          finish({ ok = false, timed_out = true, err = "Arcanum request timed out before the next attempt." })
          return
        end
        attempt, generation = attempt + 1, generation + 1
        local stage, delivered = generation, false
        local backoff = math.min(cfg.retry_base_delay_ms * 2 ^ (attempt - 1), cfg.retry_max_delay_ms)
        dbg.trace("arcanum.transport", method .. " " .. path .. " attempt=" .. attempt)
        sent, in_flight = true, true
        local started_ok, request = pcall(start_attempt, math.ceil(remaining), function(result)
          ui.dispatch(function()
            if done or delivered or stage ~= generation then
              return
            end
            delivered, in_flight = true, false
            active = nil
            uncertain = uncertain or (mutation and result.uncertain == true)
            if result.status == 429 then
              backoff = math.max(backoff, result.retry_after or 0)
              scheduler.cooldown(queue, scheduler._now() + backoff)
            end
            if result.cancelled or result.timed_out then
              finish(result)
            elseif result.ok then
              finish({ ok = true, data = result.data })
            else
              fail_or_retry(result.retryable, result.err or "Arcanum request failed.", backoff, result.status)
            end
          end)
        end)
        if not started_ok then
          if mutation then
            uncertain = true
          end
          finish({ ok = false, err = tostring(request) })
        elseif not done and not delivered and stage == generation then
          active = request
        elseif done and not delivered and request then
          pcall(request.cancel)
        end
      end)
      if not done and not began then
        queued = entry
      elseif done and not began then
        entry.cancel()
      end
    end
    enqueue(0)
  end)
  if not ok then
    finish({ ok = false, err = tostring(err) })
  end
  return handle
end

--- @param self parley.arcanum.Provider
--- @param method string
--- @param path string
--- @param body? table
--- @param opts? parley.arcanum.RequestOptions
--- @return table|nil
function M.request_run(self, method, path, body, opts)
  local result = await.callback(function(callback)
    M.request_start(self, method, path, body, callback, opts)
  end)
  if not result.ok then
    error(result.err or "Arcanum request failed", 0)
  end
  return result.data
end
return M
