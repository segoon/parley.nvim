local a = require("plenary.async.tests")
local auth = require("parley.providers.github.auth")

a.describe("GitHub credential delegation", function()
  for _, host in ipairs({ "github.com", "tenant.ghe.com", "ghe.example.com" }) do
    a.it("delegates credential selection for " .. host, function()
      local token = auth.read_token_async(host, {
        system = function(cmd, opts, callback)
          assert.same({ "gh", "auth", "token", "--hostname", host }, cmd)
          assert.equals(5000, opts.timeout)
          callback({ code = 0, stdout = " CLI_SELECTED_TOKEN\n" })
        end,
      })
      assert.equals("CLI_SELECTED_TOKEN", token)
    end)
  end
  for _, result in ipairs({
    { code = 0, stdout = " \n" },
    { code = 1, stdout = "SECRET", stderr = "SECRET" },
    { code = 124, stderr = "timeout SECRET" },
  }) do
    a.it("rejects missing credentials without leaking process output (exit " .. result.code .. ")", function()
      local token, err = auth.read_token_async("github.com", {
        system = function(_, _, callback)
          callback(result)
        end,
      })
      assert.is_nil(token)
      assert.is_nil(err:find("SECRET", 1, true))
      assert.matches("gh auth login --hostname github.com", err, 1, true)
    end)
  end
  a.it("reports an unavailable executable without exposing the spawn error", function()
    local token, err = auth.read_token_async("github.com", {
      system = function()
        error("SECRET")
      end,
    })
    assert.is_nil(token)
    assert.is_nil(err:find("SECRET", 1, true))
  end)
  a.it("keeps health checks local on new and old CLI versions", function()
    for _, legacy in ipairs({ false, true }) do
      local calls = 0
      local token = auth.read_token_async("github.com", {
        local_only = true,
        system = function(cmd, _, cb)
          calls = calls + 1
          if calls == 1 then
            assert.is_true(vim.tbl_contains(cmd, "--no-refresh"))
            if legacy then
              cb({ code = 1, stderr = "unknown flag: --no-refresh" })
              return
            end
          else
            assert.is_false(vim.tbl_contains(cmd, "--no-refresh"))
          end
          cb({ code = 0, stdout = "token" })
        end,
      })
      assert.equals("token", token)
      assert.equals(legacy and 2 or 1, calls)
    end
  end)
end)
