--- Tests for parley.providers.github.auth — GitHub authentication.
--- Run via: make test

local auth = require("parley.providers.github.auth")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Build a fake _getenv that returns values from the given map.
--- Any key not in the map returns nil.
---
--- @param env table<string, string>
--- @return fun(name: string): string|nil
local function make_getenv(env)
  return function(name)
    return env[name]
  end
end

--- Build a fake _read_file that returns the given content for any path,
--- or nil when content is nil (simulates a missing file).
---
--- @param content string|nil
--- @return fun(path: string): string|nil
local function make_read_file(content)
  return function(_path)
    return content
  end
end

--- hosts.yml content with a single github.com entry.
local SINGLE_HOST_YAML = [[
github.com:
    oauth_token: ghp_SINGLETOKEN
    user: monalisa
    git_protocol: https
]]

--- hosts.yml content with multiple hosts.
local MULTI_HOST_YAML = [[
github.com:
    oauth_token: ghp_GITHUBTOKEN
    user: monalisa
    git_protocol: https
ghe.mycompany.com:
    oauth_token: ghp_GHETOKEN
    user: corp-user
    git_protocol: ssh
ghe.example.com:
    oauth_token: ghp_EXAMPLETOKEN
    user: example-user
    git_protocol: https
]]

--- hosts.yml with a host that has no oauth_token.
local NO_TOKEN_YAML = [[
github.com:
    user: monalisa
    git_protocol: https
]]

--- hosts.yml with only an unrelated host.
local WRONG_HOST_YAML = [[
ghe.other.com:
    oauth_token: ghp_OTHERTOKEN
    user: other-user
    git_protocol: https
]]

--- hosts.yml where token value has surrounding whitespace.
--- (trailing spaces are intentional — they must be stripped by the parser)
local WHITESPACE_TOKEN_YAML = "github.com:\n    oauth_token:   ghp_SPACED   \n    user: monalisa\n"

-- ---------------------------------------------------------------------------
-- Test state
-- ---------------------------------------------------------------------------

local orig_read_file
local orig_getenv

-- ---------------------------------------------------------------------------
-- Suite: env-var fast paths
-- ---------------------------------------------------------------------------

describe("parley.providers.github.auth — env-var resolution", function()
  before_each(function()
    orig_read_file = auth._read_file
    orig_getenv = auth._getenv
    -- Default: no env vars, no file
    auth._read_file = make_read_file(nil)
    auth._getenv = make_getenv({})
  end)

  after_each(function()
    auth._read_file = orig_read_file
    auth._getenv = orig_getenv
  end)

  it("returns GH_TOKEN for github.com", function()
    auth._getenv = make_getenv({ GH_TOKEN = "ghp_FROM_GH_TOKEN" })
    local token, err = auth.read_token("github.com")
    assert.is_nil(err)
    assert.equals("ghp_FROM_GH_TOKEN", token)
  end)

  it("returns GITHUB_TOKEN for github.com when GH_TOKEN is absent", function()
    auth._getenv = make_getenv({ GITHUB_TOKEN = "ghp_FROM_GITHUB_TOKEN" })
    local token, err = auth.read_token("github.com")
    assert.is_nil(err)
    assert.equals("ghp_FROM_GITHUB_TOKEN", token)
  end)

  it("GH_TOKEN takes precedence over GITHUB_TOKEN for github.com", function()
    auth._getenv = make_getenv({
      GH_TOKEN = "ghp_FIRST",
      GITHUB_TOKEN = "ghp_SECOND",
    })
    local token, err = auth.read_token("github.com")
    assert.is_nil(err)
    assert.equals("ghp_FIRST", token)
  end)

  it("returns GH_TOKEN for a *.ghe.com subdomain", function()
    auth._getenv = make_getenv({ GH_TOKEN = "ghp_GHE_DOT_COM" })
    local token, err = auth.read_token("tenant.ghe.com")
    assert.is_nil(err)
    assert.equals("ghp_GHE_DOT_COM", token)
  end)

  it("returns GITHUB_TOKEN for *.ghe.com when GH_TOKEN absent", function()
    auth._getenv = make_getenv({ GITHUB_TOKEN = "ghp_GHE_FALLBACK" })
    local token, err = auth.read_token("tenant.ghe.com")
    assert.is_nil(err)
    assert.equals("ghp_GHE_FALLBACK", token)
  end)

  it("returns GH_ENTERPRISE_TOKEN for a GHES FQDN", function()
    auth._getenv = make_getenv({ GH_ENTERPRISE_TOKEN = "ghp_ENT_TOKEN" })
    local token, err = auth.read_token("ghe.mycompany.com")
    assert.is_nil(err)
    assert.equals("ghp_ENT_TOKEN", token)
  end)

  it("returns GITHUB_ENTERPRISE_TOKEN for GHES when GH_ENTERPRISE_TOKEN absent", function()
    auth._getenv = make_getenv({ GITHUB_ENTERPRISE_TOKEN = "ghp_ENT_FALLBACK" })
    local token, err = auth.read_token("ghe.mycompany.com")
    assert.is_nil(err)
    assert.equals("ghp_ENT_FALLBACK", token)
  end)

  it("GH_ENTERPRISE_TOKEN takes precedence over GITHUB_ENTERPRISE_TOKEN for GHES", function()
    auth._getenv = make_getenv({
      GH_ENTERPRISE_TOKEN = "ghp_ENT_FIRST",
      GITHUB_ENTERPRISE_TOKEN = "ghp_ENT_SECOND",
    })
    local token, err = auth.read_token("ghe.mycompany.com")
    assert.is_nil(err)
    assert.equals("ghp_ENT_FIRST", token)
  end)

  it("env var takes precedence over hosts.yml when both present", function()
    auth._getenv = make_getenv({ GH_TOKEN = "ghp_ENV_WINS" })
    auth._read_file = make_read_file(SINGLE_HOST_YAML)
    local token, err = auth.read_token("github.com")
    assert.is_nil(err)
    assert.equals("ghp_ENV_WINS", token)
  end)

  it("does not use GH_TOKEN for a non-ghe.com GHES host", function()
    -- GH_TOKEN must NOT apply to ghe.mycompany.com
    auth._getenv = make_getenv({
      GH_TOKEN = "ghp_WRONG",
      GH_ENTERPRISE_TOKEN = "ghp_CORRECT",
    })
    local token, err = auth.read_token("ghe.mycompany.com")
    assert.is_nil(err)
    assert.equals("ghp_CORRECT", token)
  end)
end)

-- ---------------------------------------------------------------------------
-- Suite: hosts.yml parsing
-- ---------------------------------------------------------------------------

describe("parley.providers.github.auth — hosts.yml parsing", function()
  before_each(function()
    orig_read_file = auth._read_file
    orig_getenv = auth._getenv
    -- No env vars so we always fall through to file parsing
    auth._getenv = make_getenv({})
  end)

  after_each(function()
    auth._read_file = orig_read_file
    auth._getenv = orig_getenv
  end)

  it("reads token for github.com from a single-host file", function()
    auth._read_file = make_read_file(SINGLE_HOST_YAML)
    local token, err = auth.read_token("github.com")
    assert.is_nil(err)
    assert.equals("ghp_SINGLETOKEN", token)
  end)

  it("reads token for github.com from a multi-host file", function()
    auth._read_file = make_read_file(MULTI_HOST_YAML)
    local token, err = auth.read_token("github.com")
    assert.is_nil(err)
    assert.equals("ghp_GITHUBTOKEN", token)
  end)

  it("reads token for a GHES FQDN from a multi-host file", function()
    auth._read_file = make_read_file(MULTI_HOST_YAML)
    local token, err = auth.read_token("ghe.mycompany.com")
    assert.is_nil(err)
    assert.equals("ghp_GHETOKEN", token)
  end)

  it("reads token for a second GHES FQDN from a multi-host file", function()
    auth._read_file = make_read_file(MULTI_HOST_YAML)
    local token, err = auth.read_token("ghe.example.com")
    assert.is_nil(err)
    assert.equals("ghp_EXAMPLETOKEN", token)
  end)

  it("trims surrounding whitespace from the token value", function()
    auth._read_file = make_read_file(WHITESPACE_TOKEN_YAML)
    local token, err = auth.read_token("github.com")
    assert.is_nil(err)
    assert.equals("ghp_SPACED", token)
  end)

  it("returns nil + error when file does not exist", function()
    auth._read_file = make_read_file(nil)
    local token, err = auth.read_token("github.com")
    assert.is_nil(token)
    assert.is_not_nil(err)
    assert.equals("string", type(err))
  end)

  it("returns nil + error when host is not present in the file", function()
    auth._read_file = make_read_file(WRONG_HOST_YAML)
    local token, err = auth.read_token("github.com")
    assert.is_nil(token)
    assert.is_not_nil(err)
  end)

  it("returns nil + error when host is present but has no oauth_token key", function()
    auth._read_file = make_read_file(NO_TOKEN_YAML)
    local token, err = auth.read_token("github.com")
    assert.is_nil(token)
    assert.is_not_nil(err)
  end)
end)

-- ---------------------------------------------------------------------------
-- Suite: config dir resolution
-- ---------------------------------------------------------------------------

describe("parley.providers.github.auth — config_dir resolution", function()
  before_each(function()
    orig_getenv = auth._getenv
  end)

  after_each(function()
    auth._getenv = orig_getenv
  end)

  it("uses GH_CONFIG_DIR when set", function()
    auth._getenv = make_getenv({ GH_CONFIG_DIR = "/custom/gh/config" })
    assert.equals("/custom/gh/config", auth.config_dir())
  end)

  it("uses XDG_CONFIG_HOME/gh when GH_CONFIG_DIR is absent", function()
    auth._getenv = make_getenv({ XDG_CONFIG_HOME = "/xdg/config" })
    assert.equals("/xdg/config/gh", auth.config_dir())
  end)

  it("GH_CONFIG_DIR takes precedence over XDG_CONFIG_HOME", function()
    auth._getenv = make_getenv({
      GH_CONFIG_DIR = "/custom/gh",
      XDG_CONFIG_HOME = "/xdg/config",
    })
    assert.equals("/custom/gh", auth.config_dir())
  end)

  it("falls back to HOME/.config/gh when neither GH_CONFIG_DIR nor XDG_CONFIG_HOME set", function()
    auth._getenv = make_getenv({ HOME = "/home/user" })
    assert.equals("/home/user/.config/gh", auth.config_dir())
  end)

  it("token_path appends /hosts.yml to config_dir", function()
    auth._getenv = make_getenv({ GH_CONFIG_DIR = "/my/gh" })
    assert.equals("/my/gh/hosts.yml", auth.token_path())
  end)
end)
