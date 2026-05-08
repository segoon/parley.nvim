--- parley.registry — Provider registry.
---
--- Maps buffer paths to provider instances by iterating registered
--- ProviderSpecs and calling each spec's detect function.  The first
--- spec whose detect returns true wins; its factory is called to produce
--- the provider instance.
---
--- Design notes:
---   • No VCS assumptions — detect() receives a raw buffer path and may
---     inspect anything it likes (filesystem, env vars, etc.).
---   • First-match wins; registration order is therefore significant.
---   • reset() is provided for test isolation.

local provider_mod = require("parley.provider")

local M = {}

-- ---------------------------------------------------------------------------
-- Type annotations
-- ---------------------------------------------------------------------------

--- A self-contained descriptor for one hosting provider.
---
--- @class parley.ProviderSpec
--- @field name    string                            Human-readable name (e.g. "GitHub")
--- @field detect  fun(path: string): boolean        Returns true if this provider should handle `path`
--- @field factory fun(opts: table): parley.Provider Creates and returns a provider instance

-- ---------------------------------------------------------------------------
-- Internal state
-- ---------------------------------------------------------------------------

--- @type parley.ProviderSpec[]
local _specs = {}

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Register a provider spec.
---
--- Specs are evaluated in registration order; register more-specific specs
--- before more-general ones.
---
--- @param spec parley.ProviderSpec
function M.register(spec)
  assert(type(spec) == "table", "spec must be a table")
  assert(type(spec.name) == "string" and spec.name ~= "", "spec.name must be a non-empty string")
  assert(type(spec.detect) == "function", "spec.detect must be a function")
  assert(type(spec.factory) == "function", "spec.factory must be a function")
  table.insert(_specs, spec)
end

--- Find the first registered spec whose detect(path) returns true, call its
--- factory(opts), validate the result, and return the provider.
---
--- Returns nil if no spec matches the path.
--- Raises an error (including spec.name) if the matching factory returns an
--- invalid provider.
---
--- @param path string   Buffer path passed verbatim to each detect function
--- @param opts table    Provider-specific config forwarded to factory
--- @return parley.Provider|nil
function M.resolve(path, opts)
  assert(type(path) == "string", "path must be a string")
  assert(type(opts) == "table", "opts must be a table")
  for _, spec in ipairs(_specs) do
    if spec.detect(path) then
      local p = spec.factory(opts)
      if not provider_mod.validate(p) then
        error(
          string.format(
            "parley.registry: factory for provider %q returned an invalid provider "
              .. "(missing or non-function methods)",
            spec.name
          ),
          2
        )
      end
      return p
    end
  end
  return nil
end

--- Return a shallow copy of all registered specs in registration order.
---
--- The returned list is a copy — mutations do not affect internal state.
---
--- @return parley.ProviderSpec[]
function M.registered()
  local copy = {}
  for i, spec in ipairs(_specs) do
    copy[i] = spec
  end
  return copy
end

--- Remove all registered specs.  Intended for test isolation.
function M.reset()
  _specs = {}
end

return M
