--- parley.http — Async HTTP client wrapper.
---
--- Thin wrapper around plenary.curl that:
---   • Must be called from within a plenary.async coroutine context.
---   • Optionally injects an Authorization: Bearer header from opts.token.
---   • Returns a structured parley.HttpResponse table.
---   • Raises an error string on network-level failure (curl exit ≠ 0 and
---     status == 0).  Non-2xx HTTP status codes are returned normally with
---     ok = false; callers decide whether to treat them as fatal.
---
--- Rate-limit handling (pause + retry on 429) is deferred — see POSTPONED.md.
---
--- Testability:
---   Set M._curl to a fake backend before calling any function; restore to nil
---   (or set back to nil) in after_each.  The fake must expose the same method
---   names as plenary.curl (get, post, put, patch, delete, head, request) with
---   the callback-based signature: fn(url, { ..., callback = fn(response) }).

local await = require("parley.runtime.await")

local M = {}

-- ---------------------------------------------------------------------------
-- Type annotations
-- ---------------------------------------------------------------------------

--- A structured HTTP response returned by every public function.
---
--- @class parley.HttpResponse
--- @field status  integer   HTTP status code (e.g. 200, 404)
--- @field headers table     Response headers as returned by plenary.curl
--- @field body    string    Raw response body text
--- @field ok      boolean   true iff 200 <= status < 300

-- ---------------------------------------------------------------------------
-- Injectable back-ends (for testing)
-- ---------------------------------------------------------------------------

--- Override plenary.curl in tests.  nil = use the real plenary.curl.
--- @type table|nil
M._curl = nil

--- Return the active curl backend.
--- @return table
local function curl_backend()
  return M._curl or require("plenary.curl")
end

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Wrap a plenary.curl method (callback-based) into a coroutine-safe async
--- function.  The wrapped function returns the plenary response table.
---
--- @param method_name string  e.g. "get", "post"
--- @return fun(url: string, opts: table): table
local function wrap_method(method_name)
  return function(url, opts)
    local backend = curl_backend()
    local method = backend[method_name]
    assert(type(method) == "function", "curl backend missing method: " .. method_name)
    return await.callback(function(callback)
      method(url, vim.tbl_extend("force", opts, { callback = callback }))
    end)
  end
end

--- Build the headers table to send, merging caller-supplied headers with the
--- optional Authorization header derived from opts.token.
---
--- @param opts { headers?: table, token?: string }
--- @return table
local function build_headers(opts)
  local h = {}
  if type(opts.headers) == "table" then
    for k, v in pairs(opts.headers) do
      h[k] = v
    end
  end
  if type(opts.token) == "string" and opts.token ~= "" then
    h["Authorization"] = "Bearer " .. opts.token
  end
  return h
end

--- Convert a raw plenary.curl response into a parley.HttpResponse.
--- Raises an error on network failure (exit ≠ 0 and status == 0).
---
--- @param raw table  plenary.curl response: { status, headers, body, exit }
--- @param url string  Original URL (used in error messages)
--- @return parley.HttpResponse
local function to_response(raw, url)
  local status = raw.status or 0
  local exit = raw.exit or 0

  if status == 0 and exit ~= 0 then
    error(string.format("parley.http: network error for %s (curl exit %d)", url, exit), 0)
  end

  return {
    status = status,
    headers = raw.headers or {},
    body = raw.body or "",
    ok = status >= 200 and status < 300,
  }
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Make an HTTP request inside a plenary.async coroutine context.
---
--- @param opts { url: string, method?: string, headers?: table, body?: string, token?: string }
---   url     — required
---   method  — HTTP verb (default "GET", case-insensitive)
---   headers — additional request headers
---   body    — request body (string)
---   token   — if non-empty, injects Authorization: Bearer <token>
--- @return parley.HttpResponse
function M.request(opts)
  assert(type(opts) == "table", "http.request: opts must be a table")
  assert(type(opts.url) == "string" and opts.url ~= "", "http.request: opts.url must be a non-empty string")

  local method = (opts.method or "GET"):lower()
  local headers = build_headers(opts)

  local curl_opts = { headers = headers }
  if opts.body ~= nil then
    curl_opts.body = opts.body
  end

  local async_fn = wrap_method(method)
  local raw = async_fn(opts.url, curl_opts)
  return to_response(raw, opts.url)
end

--- Perform a GET request.
---
--- @param url string
--- @param opts? { headers?: table, token?: string }
--- @return parley.HttpResponse
function M.get(url, opts)
  opts = opts or {}
  return M.request(vim.tbl_extend("force", opts, { url = url, method = "GET" }))
end

--- Perform a POST request.
---
--- @param url string
--- @param body string  Request body
--- @param opts? { headers?: table, token?: string }
--- @return parley.HttpResponse
function M.post(url, body, opts)
  opts = opts or {}
  return M.request(vim.tbl_extend("force", opts, { url = url, method = "POST", body = body }))
end

return M
