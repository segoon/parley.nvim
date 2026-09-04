--- Optional persistent cache access: a nil key never reaches disk storage.
local cache = require("parley.cache")
local M = {}
for _, method in ipairs({ "get_async", "set_async", "invalidate_async", "invalidate" }) do
  --- @param key parley.CacheKey|nil
  --- @param data? any
  --- @return any
  M[method] = function(key, data)
    if key then
      return cache[method](key, data)
    end
  end
end
return M
