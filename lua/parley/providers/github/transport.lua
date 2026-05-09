--- parley.providers.github.transport — gh CLI transport layer.
---
--- Provides two primitives for executing `gh api …` commands:
---   • gh_run   — synchronous (blocking via plenary.async), with exponential-
---                backoff retry on transient network errors.
---   • gh_start — asynchronous (callback-based), cancellable, also with retry.
---
--- Both functions operate on a parley.github.Provider table and read their
--- timeout / retry settings through transport_config().

local ui = require("parley.runtime.ui")
local dbg = require("parley.debug")

local M = {}

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

local DEFAULT_TIMEOUT_MS = 5000
local DEFAULT_RETRY_COUNT = 2
local DEFAULT_RETRY_BASE_DELAY_MS = 250
local DEFAULT_RETRY_MAX_DELAY_MS = 2000

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
}

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

---@param self parley.github.Provider
---@return { timeout_ms: integer, retry_count: integer, retry_base_delay_ms: integer, retry_max_delay_ms: integer }
function M.transport_config(self)
  local config = self._get_config and self._get_config() or nil
  local github = config and config.providers and config.providers.github or {}
  return {
    timeout_ms = github.timeout_ms or DEFAULT_TIMEOUT_MS,
    retry_count = github.retry_count or DEFAULT_RETRY_COUNT,
    retry_base_delay_ms = github.retry_base_delay_ms or DEFAULT_RETRY_BASE_DELAY_MS,
    retry_max_delay_ms = github.retry_max_delay_ms or DEFAULT_RETRY_MAX_DELAY_MS,
  }
end

---@param attempt integer
---@param cfg { retry_base_delay_ms: integer, retry_max_delay_ms: integer }
---@return integer
local function retry_delay_ms(attempt, cfg)
  return math.min(cfg.retry_base_delay_ms * (2 ^ math.max(0, attempt - 1)), cfg.retry_max_delay_ms)
end

---@param stderr string|nil
---@return boolean
local function is_retryable_error(stderr)
  local text = (stderr or ""):lower()
  for _, pattern in ipairs(RETRYABLE_ERROR_PATTERNS) do
    if text:find(pattern, 1, true) then
      return true
    end
  end
  return false
end

---@param result { code: integer, stderr: string|nil }
---@return boolean
local function is_retryable_failure(result)
  return result.code == 124 or is_retryable_error(result.stderr)
end

-- ---------------------------------------------------------------------------
-- gh_run — synchronous runner with retry
-- ---------------------------------------------------------------------------

--- Run a gh CLI command and return parsed JSON.
--- Raises on non-zero exit or JSON parse failure.
--- Returns nil (not an error) when stdout is empty (e.g. DELETE 204).
---
--- @param self  parley.github.Provider
--- @param cmd   string[]
--- @return table|nil
function M.gh_run(self, cmd)
  local runner = self._runner
  local cfg = M.transport_config(self)
  local attempts = cfg.retry_count + 1
  local result

  for attempt = 1, attempts do
    result = runner(cmd)
    if result.code == 0 then
      break
    end
    if attempt >= attempts or not is_retryable_failure(result) then
      error(string.format("parley.github: gh command failed (exit %d): %s", result.code, result.stderr or ""), 0)
    end
    self._sleep(retry_delay_ms(attempt, cfg))
  end

  local stdout = result.stdout or ""
  if stdout == "" then
    return nil
  end
  local ok_decode, decoded = pcall(vim.json.decode, stdout)
  if not ok_decode then
    error(string.format("parley.github: failed to decode JSON response: %s", stdout), 0)
  end
  return decoded
end

-- ---------------------------------------------------------------------------
-- gh_start — asynchronous cancellable runner with retry
-- ---------------------------------------------------------------------------

--- Start a cancellable gh CLI request.
--- @param self parley.github.Provider
--- @param cmd string[]
--- @param callback fun(result: { ok: boolean, data?: table, err?: string, cancelled?: boolean }): nil
--- @return { cancel: fun(): nil }
function M.gh_start(self, cmd, callback)
  local completed = false
  local cancelled = false
  local handle = nil
  local retry_timer = nil
  local cfg = M.transport_config(self)
  local attempts = cfg.retry_count + 1
  local attempt = 0

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
    handle = self._spawn(cmd, function(result)
      handle = nil
      if completed then
        return
      end

      if cancelled then
        finish({ ok = false, cancelled = true })
        return
      end

      if result.code ~= 0 then
        if attempt < attempts and is_retryable_failure(result) then
          retry_timer = self._defer(function()
            retry_timer = nil
            if completed or cancelled then
              return
            end
            start_attempt()
          end, retry_delay_ms(attempt, cfg))
          return
        end
        finish({
          ok = false,
          err = string.format("parley.github: gh command failed (exit %d): %s", result.code, result.stderr or ""),
        })
        return
      end

      local stdout = result.stdout or ""
      if stdout == "" then
        finish({ ok = true, data = nil })
        return
      end

      local ok_decode, decoded = pcall(vim.json.decode, stdout)
      if not ok_decode then
        finish({ ok = false, err = string.format("parley.github: failed to decode JSON response: %s", stdout) })
        return
      end

      finish({ ok = true, data = decoded })
    end)
  end

  start_attempt()

  return {
    cancel = function()
      if completed or cancelled then
        return
      end
      cancelled = true
      clear_retry_timer()
      if handle and handle.kill then
        pcall(function()
          handle:kill(15)
        end)
        return
      end
      finish({ ok = false, cancelled = true })
    end,
  }
end

-- ---------------------------------------------------------------------------
-- fetch_viewer_login — identity resolution
-- ---------------------------------------------------------------------------

--- Resolve and cache the authenticated user's GitHub login.
---
--- Resolution order (fast-to-slow, stops on first success):
---   1. Already cached in self._viewer_login → no-op.
---   2. `gh config get -h <host> user`  (local config, no network).
---   3. `gh api /user`                  (one API call, always authoritative).
---
--- Errors are silenced — caller treats nil _viewer_login as "unknown"
--- and defaults is_own to false.
---
--- @param self parley.github.Provider
function M.fetch_viewer_login(self)
  if self._viewer_login then
    dbg.trace("github.provider", "fetch_viewer_login: already cached → " .. self._viewer_login)
    return
  end
  -- Fast path: gh config (local, no network call)
  local result = self._runner({ "gh", "config", "get", "-h", self._host, "user" })
  dbg.trace(
    "github.provider",
    "fetch_viewer_login: gh config get → code="
      .. tostring(result.code)
      .. " stdout="
      .. vim.inspect(result.stdout or "")
      .. " stderr="
      .. vim.inspect(result.stderr or "")
  )
  if result.code == 0 and result.stdout and result.stdout:match("%S") then
    self._viewer_login = result.stdout:match("^%s*(.-)%s*$")
    dbg.trace("github.provider", "fetch_viewer_login: set via config → " .. tostring(self._viewer_login))
    return
  end
  -- Slow path: gh api /user (one API call)
  local ok, user = pcall(M.gh_run, self, { "gh", "api", "/user" })
  dbg.trace(
    "github.provider",
    "fetch_viewer_login: gh api /user → ok="
      .. tostring(ok)
      .. " login="
      .. vim.inspect(ok and user and user.login or nil)
  )
  if ok and user and user.login then
    self._viewer_login = user.login
  end
  dbg.trace("github.provider", "fetch_viewer_login: final _viewer_login=" .. vim.inspect(self._viewer_login))
end

return M
