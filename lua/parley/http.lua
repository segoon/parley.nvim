--- Async HTTP with a single cancellable callback lifecycle and a Plenary await wrapper.
local await = require("parley.runtime.await")
local ui = require("parley.runtime.ui")
local M = {}

--- @class parley.HttpResponse
--- @field status integer
--- @field headers table
--- @field body string
--- @field ok boolean True for HTTP 2xx, distinct from successful network completion.

--- @class parley.HttpResult
--- @field ok boolean
--- @field response? parley.HttpResponse
--- @field err? string
--- @field exit? integer
--- @field cancelled? boolean
--- @field timed_out? boolean
--- @field sent boolean The request may have reached the server.

--- @class parley.HttpOptions
--- @field url string
--- @field method? string
--- @field headers? table
--- @field body? string
--- @field token? string
--- @field timeout_ms? integer Default 10000; callback deadline, not just curl's synchronous timeout.

--- @type table|nil Injectable curl backend.
M._curl = nil
--- @type fun(callback: fun(), delay: integer): table
M._defer = vim.defer_fn

--- @param timer table|nil
local function close_timer(timer)
  if not timer then
    return
  end
  if timer.stop then
    pcall(timer.stop, timer)
  end
  if timer.close then
    pcall(timer.close, timer)
  end
end

--- Kill before shutdown: Plenary shutdown only closes handles.
--- @param job table|nil
local function terminate(job)
  if not job then
    return
  end
  if job.handle and not job.handle:is_closing() then
    pcall(job.handle.kill, job.handle, "sigkill")
  end
  if job.shutdown then
    pcall(job.shutdown, job, -1, 9)
  end
end

--- @param opts parley.HttpOptions
--- @param callback fun(result: parley.HttpResult)
--- @return parley.CancelHandle
function M.start(opts, callback)
  local completed, sent, aborted = false, false, false
  local timer, job
  --- @param result parley.HttpResult|table
  --- @param stop? boolean
  local function finish(result, stop)
    if completed then
      return
    end
    completed, aborted = true, stop or false
    result.sent = sent
    close_timer(timer)
    if stop then
      terminate(job)
    end
    ui.dispatch(function()
      callback(result)
    end)
  end
  local handle = {
    cancel = function()
      finish({ ok = false, cancelled = true, err = "HTTP request cancelled" }, true)
    end,
  }
  local ok, err = pcall(function()
    assert(type(opts) == "table", "http.request: opts must be a table")
    assert(type(opts.url) == "string" and opts.url ~= "", "http.request: opts.url must be a non-empty string")
    local timeout = opts.timeout_ms or 10000
    assert(type(timeout) == "number" and timeout > 0 and timeout < math.huge, "Invalid HTTP timeout")
    local backend = M._curl or require("plenary.curl")
    local method_name = (opts.method or "GET"):lower()
    local method = backend[method_name]
    assert(type(method) == "function", "curl backend missing method: " .. method_name)
    local headers = vim.tbl_extend("force", {}, opts.headers or {})
    if type(opts.token) == "string" and opts.token ~= "" then
      headers.Authorization = "Bearer " .. opts.token
    end
    timer = M._defer(function()
      finish({ ok = false, timed_out = true, err = "HTTP request timed out" }, true)
    end, math.ceil(timeout))
    if completed then
      close_timer(timer)
      return
    end
    sent = true
    job = method(opts.url, {
      headers = headers,
      body = opts.body,
      raw = { "--max-time", tostring(timeout / 1000) },
      on_error = function(failure)
        failure = type(failure) == "table" and failure or {}
        finish({
          ok = false,
          exit = failure.exit,
          err = failure.message or ("HTTP network error (curl exit " .. tostring(failure.exit) .. ")"),
        })
      end,
      callback = function(raw)
        if completed then
          return
        end
        if type(raw) ~= "table" or type(raw.status) ~= "number" then
          finish({ ok = false, err = "Invalid HTTP response" })
          return
        end
        if (raw.exit or 0) ~= 0 or raw.status == 0 then
          finish({
            ok = false,
            exit = raw.exit,
            err = "HTTP network error (curl exit " .. tostring(raw.exit or 0) .. ")",
          })
          return
        end
        finish({
          ok = true,
          response = {
            status = raw.status,
            headers = raw.headers or {},
            body = raw.body or "",
            ok = raw.status >= 200 and raw.status < 300,
          },
        })
      end,
    })
    -- Covers cancellation from a reentrant callback before method() returns its job.
    if aborted then
      terminate(job)
    end
  end)
  if not ok then
    finish({ ok = false, err = tostring(err) }, true)
  end
  return handle
end

--- @param opts parley.HttpOptions
--- @return parley.HttpResponse
function M.request(opts)
  local result = await.callback(function(callback)
    M.start(opts, callback)
  end)
  if not result.ok then
    error(result.err, 0)
  end
  return result.response
end

--- @param url string
--- @param opts? table
--- @return parley.HttpResponse
function M.get(url, opts)
  return M.request(vim.tbl_extend("force", opts or {}, { url = url, method = "GET" }))
end

--- @param url string
--- @param body string
--- @param opts? table
--- @return parley.HttpResponse
function M.post(url, body, opts)
  return M.request(vim.tbl_extend("force", opts or {}, { url = url, method = "POST", body = body }))
end
return M
