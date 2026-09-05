local response = require("parley.providers.arcanum.response")
local config = require("parley.providers.arcanum.config")

describe("Arcanum response and configuration contracts", function()
  it("parses HTTP dates in UTC regardless of the editor timezone", function()
    assert.equals(3000, response.retry_after({ "Retry-After: Wed, 21 Oct 2015 07:28:00 GMT" }, 1445412477))
    assert.equals(0, response.retry_after({ "Retry-After: Thu, 01 Jan 1970 00:00:00 GMT" }, 1))
    assert.is_nil(response.retry_after({ "Retry-After: Thu, 31 Feb 2026 00:00:00 GMT" }, 0))
  end)
  it("handles repeated, case-insensitive and invalid delay headers", function()
    assert.equals(4000, response.retry_after({ "rEtRy-AfTeR:  2 ", "Retry-After: 4" }, 0))
    assert.equals(5000, response.retry_after({ ["retry-after"] = " 5 " }, 0))
    for _, value in ipairs({ "garbage", "-1", "1.5", "" }) do
      assert.is_nil(response.retry_after({ "Retry-After: " .. value }, 0))
    end
  end)
  it("validates nullable envelope fields without placeholder successes", function()
    assert.is_nil(response.unwrap({ status = 200, ok = true, body = '{"data":null,"errors":null}' }))
    assert.same({}, response.unwrap({ status = 200, ok = true, body = '{"data":[],"errors":[]}' }))
    for _, body in ipairs({
      "{}",
      "[]",
      "false",
      '{"data":1}',
      '{"errors":true}',
      '{"errors":["denied"]}',
      '{"errors":{"message":"denied"},"data":{}}',
    }) do
      assert.is_false(pcall(response.unwrap, { status = 200, ok = true, body = body }))
    end
  end)
  it("defaults to paced reads and opt-in writes and rejects invalid timing settings", function()
    assert.equals(1000, config.resolve().request_interval_ms)
    assert.is_false(config.resolve().idempotent_write_retries)
    for _, values in ipairs({
      { timeout_ms = 0 },
      { request_interval_ms = 0 },
      { retry_count = -1 },
      { retry_base_delay_ms = -1 },
      { retry_max_delay_ms = math.huge },
      { idempotent_write_retries = "yes" },
    }) do
      assert.is_false(pcall(config.resolve, values))
    end
  end)
end)
