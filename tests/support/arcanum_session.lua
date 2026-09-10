--- Establish a verified API account for mutation-focused tests using the real preparation path.
--- @param provider parley.arcanum.Provider
--- @param login? string
return function(provider, login)
  local transport = require("parley.providers.arcanum.transport")
  local saved = transport.http_run
  transport.http_run = function(_, method, path)
    assert.equals("GET", method)
    assert.equals("/v2/users/me?fields=name", path)
    return { name = login or "alice" }
  end
  local ok, err = pcall(provider.prepare, provider)
  transport.http_run = saved
  assert(ok, err)
end
