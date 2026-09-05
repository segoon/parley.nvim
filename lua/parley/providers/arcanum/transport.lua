--- parley.providers.arcanum.transport — Arcanum HTTP transport layer.
---
--- Provides two primitives for executing Arcanum REST API calls:
---   • http_run   — synchronous (blocking via plenary.async), with exponential-
---                  backoff retry on transient network errors.
---   • http_start — asynchronous (callback-based), cancellable, also with retry.
---
--- Both functions operate on a parley.arcanum.Provider table and read their
--- timeout / retry settings through transport_config().
---
--- All responses use the Arcanum wrapper: { data: T, errors: [...] }.
--- http_run / http_start unwrap `data` on success and raise / callback-fail
--- on API-level errors.
---
--- Authentication: every request adds "Authorization: OAuth <token>" header.

local http = require("parley.http")
local dbg = require("parley.debug")
local ui = require("parley.runtime.ui")

local M = {}

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

local RESPONSE_BODY_LOG_LIMIT = 2000

local RETRYABLE_HTTP_STATUSES = { 429, 500, 502, 503, 504 }

local RETRYABLE_ERROR_PATTERNS = {
  "i/o timeout",
  "tls handshake timeout",
  "connection reset",
  "connection refused",
  "no such host",
  "temporary failure in name resolution",
  "timeout awaiting response headers",
  "context deadline exceeded",
  "network is unreachable",
  "software caused connection abort",
  "connection timed out",
}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- @param self parley.arcanum.Provider
--- @return { timeout_ms: integer, retry_count: integer, retry_base_delay_ms: integer, retry_max_delay_ms: integer }
function M.transport_config(self)
  return self._config
end

--- @param attempt integer
--- @param cfg { retry_base_delay_ms: integer, retry_max_delay_ms: integer }
--- @return integer
local function retry_delay_ms(attempt, cfg)
  return math.min(cfg.retry_base_delay_ms * (2 ^ math.max(0, attempt - 1)), cfg.retry_max_delay_ms)
end

--- @param status integer
--- @return boolean
local function is_retryable_status(status)
  for _, s in ipairs(RETRYABLE_HTTP_STATUSES) do
    if status == s then
      return true
    end
  end
  return false
end

--- @param err string|nil
--- @return boolean
local function is_retryable_error(err)
  local text = (err or ""):lower()
  for _, pattern in ipairs(RETRYABLE_ERROR_PATTERNS) do
    if text:find(pattern, 1, true) then
      return true
    end
  end
  return false
end

--- @param body string|nil
--- @return string
local function format_body_for_log(body)
  if type(body) ~= "string" or body == "" then
    return "<empty>"
  end

  local clipped = body
  local truncated = false
  if #clipped > RESPONSE_BODY_LOG_LIMIT then
    clipped = clipped:sub(1, RESPONSE_BODY_LOG_LIMIT)
    truncated = true
  end

  local logged = vim.inspect(clipped)
  if truncated then
    logged = logged .. "...<truncated>"
  end
  return logged
end

--- Unwrap the Arcanum response envelope { data, errors }.
--- Returns data (may be nil for 204-style responses) on success.
--- Raises an error string on API-level errors.
--- @param response parley.HttpResponse
--- @param url string
--- @return table|nil
local function unwrap_response(response, url)
  -- 204 No Content — success with no body
  if response.status == 204 then
    return nil
  end

  if response.body == "" then
    return nil
  end

  local ok_decode, decoded = pcall(vim.json.decode, response.body)
  if not ok_decode then
    error(string.format("parley.arcanum: failed to decode JSON from %s: %s", url, response.body), 0)
  end

  -- Check API-level errors
  if decoded.errors and #decoded.errors > 0 then
    local msgs = {}
    for _, e in ipairs(decoded.errors) do
      table.insert(msgs, (e.message or e.status or tostring(e)))
    end
    error(string.format("parley.arcanum: API error from %s: %s", url, table.concat(msgs, "; ")), 0)
  end

  return decoded.data
end

--- Build the full URL for an API path.
--- @param self parley.arcanum.Provider
--- @param path string  e.g. "/v1/pull-requests/cursor"
--- @return string
function M.api_url(self, path)
  return "https://" .. self._host .. "/api" .. path
end

--- Build common request headers (auth + content-type).
--- @param self parley.arcanum.Provider
--- @return table<string, string>
local function build_headers(self)
  local token = self._token or ""
  return {
    ["Authorization"] = "OAuth " .. token,
    ["Content-Type"] = "application/json",
    ["Accept"] = "application/json",
  }
end

-- ---------------------------------------------------------------------------
-- http_run — synchronous runner with retry
-- ---------------------------------------------------------------------------

--- Run an Arcanum REST API request and return unwrapped data.
--- Raises on non-2xx status (after exhausting retries) or API errors.
--- Returns nil for 204 / empty body.
---
--- @param self   parley.arcanum.Provider
--- @param method string   HTTP verb ("GET", "POST", "PATCH", "DELETE", "PUT")
--- @param path   string   API path (e.g. "/v1/pull-requests/cursor")
--- @param body?  table    Request body (will be JSON-encoded)
--- @return table|nil
function M.http_run(self, method, path, body)
  local url = M.api_url(self, path)
  local cfg = M.transport_config(self)
  local attempts = cfg.retry_count + 1
  local headers = build_headers(self)
  local body_str = body and vim.json.encode(body) or nil

  dbg.trace("arcanum.transport", "http_run: " .. method .. " " .. url)

  for attempt = 1, attempts do
    local ok, result = pcall(http.request, {
      url = url,
      method = method,
      headers = headers,
      body = body_str,
    })

    if not ok then
      -- Network-level error (curl failed)
      if attempt >= attempts or not is_retryable_error(tostring(result)) then
        error(string.format("parley.arcanum: request failed: %s", tostring(result)), 0)
      end
      dbg.trace(
        "arcanum.transport",
        "http_run: attempt=" .. attempt .. " network error, retrying: " .. tostring(result)
      )
      self._sleep(retry_delay_ms(attempt, cfg))
    else
      dbg.trace(
        "arcanum.transport",
        "http_run: attempt="
          .. attempt
          .. " status="
          .. tostring(result.status)
          .. " body="
          .. format_body_for_log(result.body)
      )

      if result.ok then
        return unwrap_response(result, url)
      end

      if attempt >= attempts or not is_retryable_status(result.status) then
        -- Try to extract error message from body
        local err_msg = result.body or ""
        local ok2, decoded = pcall(vim.json.decode, err_msg)
        if ok2 and decoded and decoded.errors and #decoded.errors > 0 then
          local msgs = {}
          for _, e in ipairs(decoded.errors) do
            table.insert(msgs, (e.message or e.status or tostring(e)))
          end
          err_msg = table.concat(msgs, "; ")
        end
        error(string.format("parley.arcanum: HTTP %d from %s: %s", result.status, url, err_msg), 0)
      end

      dbg.trace("arcanum.transport", "http_run: attempt=" .. attempt .. " status=" .. result.status .. " retrying")
      self._sleep(retry_delay_ms(attempt, cfg))
    end
  end
end

-- ---------------------------------------------------------------------------
-- http_start — asynchronous cancellable runner with retry
-- ---------------------------------------------------------------------------

--- Start a cancellable Arcanum REST API request.
--- @param self     parley.arcanum.Provider
--- @param method   string  HTTP verb
--- @param path     string  API path
--- @param body?    table   Request body (JSON-encoded)
--- @param callback fun(result: { ok: boolean, data?: table, err?: string, cancelled?: boolean }): nil
--- @return { cancel: fun(): nil }
function M.http_start(self, method, path, body, callback)
  local completed = false
  local cancelled = false
  local retry_timer = nil
  local cfg = M.transport_config(self)
  local attempts = cfg.retry_count + 1
  local attempt = 0
  local url = M.api_url(self, path)
  local headers = build_headers(self)
  local body_str = body and vim.json.encode(body) or nil

  dbg.trace("arcanum.transport", "http_start: " .. method .. " " .. url)

  local function clear_retry_timer()
    if not retry_timer then
      return
    end
    if retry_timer.stop then
      pcall(function()
        retry_timer:stop()
      end)
    end
    if retry_timer.close then
      pcall(function()
        retry_timer:close()
      end)
    end
    retry_timer = nil
  end

  local function finish(result)
    if completed then
      return
    end
    completed = true
    clear_retry_timer()
    ui.dispatch(function()
      callback(result)
    end)
  end

  local function start_attempt()
    attempt = attempt + 1
    dbg.trace("arcanum.transport", "http_start: attempt=" .. attempt)

    -- Use plenary.curl directly for async (non-blocking) operation.
    local curl_backend = require("plenary.curl")
    local method_fn = curl_backend[method:lower()]
    if not method_fn then
      finish({ ok = false, err = "parley.arcanum: unsupported HTTP method: " .. method })
      return
    end

    local curl_opts = {
      headers = headers,
      callback = function(raw_result)
        if completed then
          return
        end
        if cancelled then
          finish({ ok = false, cancelled = true })
          return
        end

        -- Network failure
        if (raw_result.exit or 0) ~= 0 and (raw_result.status or 0) == 0 then
          local err = string.format("parley.arcanum: network error (curl exit %d)", raw_result.exit or 0)
          if attempt < attempts and is_retryable_error(err) then
            retry_timer = self._defer(function()
              retry_timer = nil
              if completed or cancelled then
                return
              end
              start_attempt()
            end, retry_delay_ms(attempt, cfg))
            return
          end
          finish({ ok = false, err = err })
          return
        end

        local status = raw_result.status or 0
        local body_resp = raw_result.body or ""

        dbg.trace(
          "arcanum.transport",
          "http_start: attempt="
            .. attempt
            .. " status="
            .. tostring(status)
            .. " body="
            .. format_body_for_log(body_resp)
        )

        if status >= 200 and status < 300 then
          -- Success
          local ok_u, data_or_err = pcall(function()
            local resp = { status = status, body = body_resp, ok = true }
            return unwrap_response(resp, url)
          end)
          if ok_u then
            finish({ ok = true, data = data_or_err })
          else
            finish({ ok = false, err = tostring(data_or_err) })
          end
          return
        end

        -- Non-2xx
        if attempt < attempts and is_retryable_status(status) then
          retry_timer = self._defer(function()
            retry_timer = nil
            if completed or cancelled then
              return
            end
            start_attempt()
          end, retry_delay_ms(attempt, cfg))
          return
        end

        local err_msg = body_resp
        local ok2, decoded = pcall(vim.json.decode, err_msg)
        if ok2 and decoded and decoded.errors and #decoded.errors > 0 then
          local msgs = {}
          for _, e in ipairs(decoded.errors) do
            table.insert(msgs, (e.message or e.status or tostring(e)))
          end
          err_msg = table.concat(msgs, "; ")
        end
        finish({
          ok = false,
          err = string.format("parley.arcanum: HTTP %d from %s: %s", status, url, err_msg),
        })
      end,
    }

    if body_str then
      curl_opts.body = body_str
    end

    method_fn(url, curl_opts)
  end

  start_attempt()

  return {
    cancel = function()
      if completed or cancelled then
        return
      end
      cancelled = true
      clear_retry_timer()
      finish({ ok = false, cancelled = true })
    end,
  }
end

return M
