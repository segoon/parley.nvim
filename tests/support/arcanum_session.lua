--- Establish the configured Arc account using the real preparation path.
--- @param provider parley.arcanum.Provider
--- @param login? string
return function(provider, login)
  provider._arc_login = login or "alice"
  provider:prepare()
end
