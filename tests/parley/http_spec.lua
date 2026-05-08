--- Tests for parley.http — async HTTP client wrapper.
--- Run via: make test

local async_tests = require("plenary.async.tests")
local http = require("parley.http")

-- ---------------------------------------------------------------------------
-- Fake curl backend helpers
-- ---------------------------------------------------------------------------

--- Build a fake plenary.curl-compatible backend.
--- Each method accepts (url, opts) where opts.callback is called with a
--- plenary-style response table: { status, headers, body, exit }.
---
--- @param responses table  Ordered list of response tables to return.
---   Each entry: { status: integer, headers?: table, body?: string, exit?: integer }
---   Consumed in FIFO order; the last entry is reused when the list is exhausted.
--- @return table  fake curl backend, table  call log (each entry: { url, opts })
local function make_fake_curl(responses)
  local calls = {}
  local index = 0

  local function next_response()
    index = index + 1
    return responses[index] or responses[#responses]
  end

  local function make_method(method_name)
    return function(url, opts)
      local r = next_response()
      table.insert(calls, { method = method_name, url = url, opts = opts })
      if opts and opts.callback then
        opts.callback({
          status = r.status or 200,
          headers = r.headers or {},
          body = r.body or "",
          exit = r.exit or 0,
        })
      end
    end
  end

  local backend = {
    get = make_method("get"),
    post = make_method("post"),
    put = make_method("put"),
    patch = make_method("patch"),
    delete = make_method("delete"),
    head = make_method("head"),
    request = make_method("request"),
  }
  return backend, calls
end

--- Reset http module test state between tests.
local function reset_http()
  http._curl = nil
end

-- ---------------------------------------------------------------------------
-- parley.http.request — basics
-- ---------------------------------------------------------------------------

async_tests.describe("parley.http.request basics", function()
  async_tests.before_each(reset_http)

  async_tests.it("returns HttpResponse with status and body on 200", function()
    local backend, _ = make_fake_curl({ { status = 200, body = "hello" } })
    http._curl = backend

    local resp = http.request({ url = "https://example.com/api" })

    assert.equals(200, resp.status)
    assert.equals("hello", resp.body)
    assert.is_true(resp.ok)
  end)

  async_tests.it("ok is false for 404", function()
    local backend, _ = make_fake_curl({ { status = 404, body = "not found" } })
    http._curl = backend

    local resp = http.request({ url = "https://example.com/missing" })

    assert.equals(404, resp.status)
    assert.is_false(resp.ok)
  end)

  async_tests.it("ok is false for 500", function()
    local backend, _ = make_fake_curl({ { status = 500 } })
    http._curl = backend

    local resp = http.request({ url = "https://example.com/" })

    assert.is_false(resp.ok)
  end)

  async_tests.it("returns headers from response", function()
    local backend, _ = make_fake_curl({
      { status = 200, headers = { ["content-type"] = "application/json" } },
    })
    http._curl = backend

    local resp = http.request({ url = "https://example.com/" })

    assert.equals("application/json", resp.headers["content-type"])
  end)

  async_tests.it("raises an error when curl exit is non-zero and status is 0", function()
    local backend, _ = make_fake_curl({ { status = 0, exit = 1, body = "" } })
    http._curl = backend

    assert.has_error(function()
      http.request({ url = "https://example.com/" })
    end)
  end)
end)

-- ---------------------------------------------------------------------------
-- Auth header injection
-- ---------------------------------------------------------------------------

async_tests.describe("parley.http.request auth injection", function()
  async_tests.before_each(reset_http)

  async_tests.it("injects Authorization: Bearer when token is given", function()
    local backend, calls = make_fake_curl({ { status = 200 } })
    http._curl = backend

    http.request({ url = "https://example.com/", token = "mytoken" })

    local sent_headers = calls[1].opts.headers or {}
    assert.equals("Bearer mytoken", sent_headers["Authorization"])
  end)

  async_tests.it("does not inject Authorization when token is absent", function()
    local backend, calls = make_fake_curl({ { status = 200 } })
    http._curl = backend

    http.request({ url = "https://example.com/" })

    local sent_headers = calls[1].opts.headers or {}
    assert.is_nil(sent_headers["Authorization"])
  end)

  async_tests.it("does not inject Authorization when token is empty string", function()
    local backend, calls = make_fake_curl({ { status = 200 } })
    http._curl = backend

    http.request({ url = "https://example.com/", token = "" })

    local sent_headers = calls[1].opts.headers or {}
    assert.is_nil(sent_headers["Authorization"])
  end)
end)

-- ---------------------------------------------------------------------------
-- Custom headers
-- ---------------------------------------------------------------------------

async_tests.describe("parley.http.request custom headers", function()
  async_tests.before_each(reset_http)

  async_tests.it("passes caller-supplied headers through", function()
    local backend, calls = make_fake_curl({ { status = 200 } })
    http._curl = backend

    http.request({
      url = "https://example.com/",
      headers = { ["X-Custom"] = "yes", Accept = "application/json" },
    })

    local sent = calls[1].opts.headers or {}
    assert.equals("yes", sent["X-Custom"])
    assert.equals("application/json", sent["Accept"])
  end)

  async_tests.it("merges custom headers with auth header", function()
    local backend, calls = make_fake_curl({ { status = 200 } })
    http._curl = backend

    http.request({
      url = "https://example.com/",
      token = "tok",
      headers = { ["X-Foo"] = "bar" },
    })

    local sent = calls[1].opts.headers or {}
    assert.equals("Bearer tok", sent["Authorization"])
    assert.equals("bar", sent["X-Foo"])
  end)
end)

-- ---------------------------------------------------------------------------
-- HTTP method routing
-- ---------------------------------------------------------------------------

async_tests.describe("parley.http.request method routing", function()
  async_tests.before_each(reset_http)

  async_tests.it("defaults to GET", function()
    local backend, calls = make_fake_curl({ { status = 200 } })
    http._curl = backend

    http.request({ url = "https://example.com/" })

    assert.equals("get", calls[1].method)
  end)

  async_tests.it("uses POST when method = POST", function()
    local backend, calls = make_fake_curl({ { status = 201 } })
    http._curl = backend

    http.request({ url = "https://example.com/", method = "POST", body = "{}" })

    assert.equals("post", calls[1].method)
  end)

  async_tests.it("passes body to the curl backend", function()
    local backend, calls = make_fake_curl({ { status = 201 } })
    http._curl = backend

    http.request({ url = "https://example.com/", method = "POST", body = '{"x":1}' })

    assert.equals('{"x":1}', calls[1].opts.body)
  end)
end)

-- ---------------------------------------------------------------------------
-- Convenience wrappers
-- ---------------------------------------------------------------------------

async_tests.describe("parley.http.get", function()
  async_tests.before_each(reset_http)

  async_tests.it("issues a GET request and returns HttpResponse", function()
    local backend, calls = make_fake_curl({ { status = 200, body = "ok" } })
    http._curl = backend

    local resp = http.get("https://example.com/thing")

    assert.equals("get", calls[1].method)
    assert.equals(200, resp.status)
    assert.equals("ok", resp.body)
  end)

  async_tests.it("forwards opts.token as auth header", function()
    local backend, calls = make_fake_curl({ { status = 200 } })
    http._curl = backend

    http.get("https://example.com/", { token = "abc" })

    assert.equals("Bearer abc", (calls[1].opts.headers or {})["Authorization"])
  end)
end)

async_tests.describe("parley.http.post", function()
  async_tests.before_each(reset_http)

  async_tests.it("issues a POST request with the given body", function()
    local backend, calls = make_fake_curl({ { status = 201 } })
    http._curl = backend

    local resp = http.post("https://example.com/items", '{"name":"x"}')

    assert.equals("post", calls[1].method)
    assert.equals('{"name":"x"}', calls[1].opts.body)
    assert.equals(201, resp.status)
  end)

  async_tests.it("forwards opts.token as auth header", function()
    local backend, calls = make_fake_curl({ { status = 201 } })
    http._curl = backend

    http.post("https://example.com/items", "{}", { token = "xyz" })

    assert.equals("Bearer xyz", (calls[1].opts.headers or {})["Authorization"])
  end)
end)
