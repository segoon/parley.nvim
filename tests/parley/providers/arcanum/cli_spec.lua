local cli = require("parley.providers.arcanum.cli")
local requests = require("parley.providers.arcanum.requests")

describe("Arcanum CLI requests", function()
  local saved, calls
  before_each(function()
    saved, calls = cli._system, {}
    cli._system = function(argv, opts, callback)
      calls[#calls + 1] = { argv = argv, opts = opts, callback = callback }
      return { kill = function() end }
    end
  end)
  after_each(function()
    cli._system = saved
  end)

  it("pins credentials and host and keeps literal bodies out of arguments", function()
    local body = "quotes ' and `ticks`\n$(literal)\n"
    local spec = requests.create_inline(12, 42, {
      content = body,
      entry_id = "opaque",
      side = "new",
      line = 7,
      size = 2,
    }, false)
    cli.start(spec, "https://custom.example/api", "secret", 900, function() end)
    assert.same({
      "ya",
      "tool",
      "arcanum",
      "--json",
      "--api-url",
      "https://custom.example/api",
      "comment",
      "post-diff",
      "--diff-id",
      "42",
      "--entry-id",
      "opaque",
      "--line",
      "7",
      "--side",
      "new",
      "--size",
      "2",
      "--content-file",
      "/dev/stdin",
    }, calls[1].argv)
    assert.equals(body, calls[1].opts.stdin)
    assert.equals("secret", calls[1].opts.env.ARC_TOKEN)
    assert.equals("", calls[1].opts.env.ARCANUM_CLI_REVIEW_SYSTEM)
    assert.equals(900, calls[1].opts.timeout)
  end)

  it("reports a missing executable without exposing credentials", function()
    cli._system = function()
      error("secret")
    end
    local result
    cli.start({ args = { "pr", "get" } }, "https://host/api", "secret", 900, function(r)
      result = r
    end)
    assert.is_false(result.ok)
    assert.is_false(result.sent)
    assert.is_nil(result.err:find("secret", 1, true))
    assert.matches("Cannot start", result.err)
  end)

  it("reports a process timeout as an uncertain write outcome", function()
    local result
    cli.start({ args = { "comment", "reply" } }, "https://host/api", "secret", 900, function(r)
      result = r
    end)
    calls[1].callback({ code = 124, stdout = "", stderr = "" })
    assert.is_true(result.timed_out)
    assert.is_true(result.uncertain)
    assert.matches("timed out", result.err)
  end)

  it("preserves structured error status without retrying a mutation", function()
    local result
    cli.start({ args = { "comment", "delete" } }, "https://host/api", "secret", 900, function(r)
      result = r
    end)
    calls[1].callback({
      code = 65,
      stdout = vim.json.encode({
        error = {
          code = "CONFLICT",
          http_status = 409,
          message = "conflict",
        },
      }),
      stderr = "",
    })
    assert.is_false(result.ok)
    assert.equals(409, result.status)
    assert.equals(1, #calls)
  end)
end)
