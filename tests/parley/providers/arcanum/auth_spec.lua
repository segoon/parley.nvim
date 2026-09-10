--- Tests for parley.providers.arcanum.auth — Arcanum token resolution.
--- Run via: make test

local auth = require("parley.providers.arcanum.auth")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local saved = {}

local function save_seams()
  saved.getenv = auth._getenv
  saved.read_file = auth._read_file
end

local function restore_seams()
  auth._getenv = saved.getenv
  auth._read_file = saved.read_file
end

-- ---------------------------------------------------------------------------
-- Suite
-- ---------------------------------------------------------------------------

describe("parley.providers.arcanum.auth — read_token", function()
  before_each(save_seams)
  after_each(restore_seams)

  -- ── Env var takes priority ─────────────────────────────────────────────

  it("returns token from ARCANUM_TOKEN env var", function()
    auth._getenv = function(name)
      if name == "ARCANUM_TOKEN" then
        return "my-oauth-token"
      end
      return nil
    end
    auth._read_file = function(_path)
      return nil
    end

    local token, err = auth.read_token()

    assert.equals("my-oauth-token", token)
    assert.is_nil(err)
  end)

  it("does not read file when ARCANUM_TOKEN env var is set", function()
    local file_called = false
    auth._getenv = function(name)
      if name == "ARCANUM_TOKEN" then
        return "env-token"
      end
      return nil
    end
    auth._read_file = function(_path)
      file_called = true
      return "file-token"
    end

    auth.read_token()

    assert.is_false(file_called)
  end)

  -- ── File fallback ──────────────────────────────────────────────────────

  it("falls back to ~/.arc/token when env var is absent", function()
    auth._getenv = function(name)
      return name == "HOME" and "/home/test" or nil
    end
    auth._read_file = function(_path)
      return "file-oauth-token\n"
    end

    local token, err = auth.read_token()

    assert.equals("file-oauth-token", token)
    assert.is_nil(err)
  end)

  it("reads from ~/.arc/token path", function()
    local read_path = nil
    auth._getenv = function(name)
      if name == "HOME" then
        return "/home/user"
      end
      return nil
    end
    auth._read_file = function(path)
      read_path = path
      return "token123"
    end

    auth.read_token()

    assert.equals("/home/user/.arc/token", read_path)
  end)

  it("trims whitespace from file token", function()
    auth._getenv = function(name)
      return name == "HOME" and "/home/test" or nil
    end
    auth._read_file = function(_path)
      return "  trimmed-token  \n"
    end

    local token, _ = auth.read_token()

    assert.equals("trimmed-token", token)
  end)

  -- ── Failure cases ──────────────────────────────────────────────────────

  it("returns nil + error when no token found", function()
    auth._getenv = function(name)
      return name == "HOME" and "/home/test" or nil
    end
    auth._read_file = function(_path)
      return nil
    end

    local token, err = auth.read_token()

    assert.is_nil(token)
    assert.is_not_nil(err)
    assert.is_truthy(err:find("ARCANUM_TOKEN", 1, true))
  end)

  it("returns nil + error when file contains only whitespace", function()
    auth._getenv = function(name)
      return name == "HOME" and "/home/test" or nil
    end
    auth._read_file = function(_path)
      return "   \n\t  "
    end

    local token, err = auth.read_token()

    assert.is_nil(token)
    assert.is_not_nil(err)
  end)

  it("skips empty ARCANUM_TOKEN env var and tries file", function()
    auth._getenv = function(name)
      if name == "HOME" then
        return "/home/test"
      end
      if name == "ARCANUM_TOKEN" then
        return ""
      end
      return nil
    end
    auth._read_file = function(_path)
      return "file-token"
    end

    local token, _ = auth.read_token()

    assert.equals("file-token", token)
  end)

  -- ── read_token_async alias ──────────────────────────────────────────────

  it("read_token_async returns same result as read_token", function()
    auth._getenv = function(name)
      if name == "ARCANUM_TOKEN" then
        return "async-token"
      end
      return nil
    end
    auth._read_file = function(_path)
      return nil
    end

    local token, err = auth.read_token_async()

    assert.equals("async-token", token)
    assert.is_nil(err)
  end)
end)
