--- Arcanum-owned configuration and defaults.
local M = {}
--- @class parley.ArcanumProviderConfig
--- @field timeout_ms integer
--- @field retry_count integer
--- @field retry_base_delay_ms integer
--- @field retry_max_delay_ms integer
--- @field host string
--- @field request_interval_ms integer Minimum spacing between request starts.
--- @field idempotent_write_retries boolean Confirm deployment support before enabling.
local defaults = {
  timeout_ms = 10000,
  request_interval_ms = 1000,
  idempotent_write_retries = false,
  retry_count = 2,
  retry_base_delay_ms = 250,
  retry_max_delay_ms = 2000,
  host = "arcanum.yandex.net",
}
--- @param opts? table
--- @return parley.ArcanumProviderConfig
function M.resolve(opts)
  local config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), vim.deepcopy(opts or {}))
  for _, name in ipairs({
    "timeout_ms",
    "request_interval_ms",
    "retry_count",
    "retry_base_delay_ms",
    "retry_max_delay_ms",
  }) do
    local value = config[name]
    local minimum = (name == "timeout_ms" or name == "request_interval_ms") and 1 or 0
    assert(
      type(value) == "number" and value >= minimum and value < math.huge and value == math.floor(value),
      "providers.arcanum." .. name .. " must be an integer >= " .. minimum
    )
  end
  assert(
    type(config.idempotent_write_retries) == "boolean",
    "providers.arcanum.idempotent_write_retries must be boolean"
  )
  assert(
    require("parley.providers.arcanum.host").valid(config.host),
    "providers.arcanum.host must be a hostname or bracketed IPv6 address with an optional port"
  )
  config.host = config.host:lower()
  return config
end
return M
