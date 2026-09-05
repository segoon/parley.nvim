local auth = require("parley.providers.arcanum.auth")
describe("Arc credential sources", function()
  local saved, env, files, reads
  before_each(function()
    saved = { auth._getenv, auth._read_file }
    env, files, reads = { HOME = "/home/test" }, {}, {}
    auth._getenv = function(k)
      return env[k]
    end
    auth._read_file = function(p)
      reads[#reads + 1] = p
      return files[p]
    end
  end)
  after_each(function()
    auth._getenv, auth._read_file = saved[1], saved[2]
  end)
  it("prefers explicit token values and trims whitespace", function()
    env.ARCANUM_TOKEN, env.ARC_OAUTH_TOKEN = " first \n", "second"
    local token, err, source = auth.read_token()
    assert.equals("first", token)
    assert.is_nil(err)
    assert.equals("ARCANUM_TOKEN", source)
    env.ARCANUM_TOKEN = " \n"
    assert.equals("second", auth.read_token())
    assert.same({}, reads)
  end)
  it("uses an explicit path before the default token file", function()
    env.ARC_TOKEN_PATH = "/chosen"
    files["/chosen"], files["/home/test/.arc/token"] = " chosen\n", "default"
    local token, _, source = auth.read_token()
    assert.equals("chosen", token)
    assert.equals("ARC_TOKEN_PATH", source)
    assert.same({ "/chosen" }, reads)
  end)
  it("does not fall back from a broken explicit path", function()
    env.ARC_TOKEN_PATH = "/missing"
    files["/home/test/.arc/token"] = "wrong-account"
    local token, err = auth.read_token()
    assert.is_nil(token)
    assert.matches("ARC_TOKEN_PATH", err)
    assert.same({ "/missing" }, reads)
  end)
  it("does not probe /.arc/token when HOME is missing", function()
    env.HOME = nil
    assert.is_nil(auth.read_token())
    assert.same({}, reads)
  end)
end)
