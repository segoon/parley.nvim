--- Arcanum transport: one deadline across pacing, HTTP attempts, and retries.
local http = require("parley.http")
local ui = require("parley.runtime.ui")
local await = require("parley.runtime.await")
local scheduler = require("parley.providers.arcanum.scheduler")
local response = require("parley.providers.arcanum.response")
local dbg = require("parley.debug")
local M = {}

--- @class parley.arcanum.RequestOptions
--- @field retry_policy? 'read'|'create'|'none' GET/HEAD default to read; all other methods default to none.
--- @class parley.arcanum.TransportResult
--- @field ok boolean
--- @field data? table
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
--- @return parley.ArcanumProviderConfig
function M.transport_config(self)
  return self._config
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
function M.http_start(self, method, path, body, callback, opts)
  local created = scheduler._now()
  local verified_token, host = self._verified_token, self._host
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
      verified_token
      and (
        self._verified_token ~= verified_token
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
    if policy == "create" then
      headers["Idempotency-Key"] = M._key()
    end
    local can_retry = policy == "read" or (policy == "create" and cfg.idempotent_write_retries)
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
    local function fail_or_retry(retryable, message, delay)
      if can_retry and retryable and attempt <= cfg.retry_count then
        enqueue(delay)
      else
        finish({ ok = false, err = message })
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
          verified_token
          and (
            self._verified_token ~= verified_token
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
        local started_ok, request = pcall(http.start, {
          url = url,
          method = method,
          headers = vim.deepcopy(headers),
          body = serialized,
          timeout_ms = math.ceil(remaining),
        }, function(result)
          ui.dispatch(function()
            if done or delivered or stage ~= generation then
              return
            end
            delivered, in_flight = true, false
            active = nil
            if not result.ok then
              if mutation and result.sent ~= false then
                uncertain = true
              end
              if result.cancelled then
                finish(result)
                return
              end
              fail_or_retry(response.retry_exit(result.exit), result.err or "Arcanum network request failed.", backoff)
              return
            end
            local raw = result.response
            if mutation and raw.status >= 500 then
              uncertain = true
            end
            if raw.status == 429 then
              backoff = math.max(backoff, response.retry_after(raw.headers, M._wall_time()) or 0)
              scheduler.cooldown(queue, scheduler._now() + backoff)
            end
            local valid, data = pcall(response.unwrap, raw)
            if raw.ok then
              if not valid and mutation then
                uncertain = true
              end
              finish(valid and { ok = true, data = data } or { ok = false, err = tostring(data) })
            else
              fail_or_retry(
                response.retry_status(raw.status),
                valid and ("Arcanum HTTP " .. raw.status) or tostring(data),
                backoff
              )
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
function M.http_run(self, method, path, body, opts)
  local result = await.callback(function(callback)
    M.http_start(self, method, path, body, callback, opts)
  end)
  if not result.ok then
    error(result.err or "Arcanum request failed", 0)
  end
  return result.data
end
return M
