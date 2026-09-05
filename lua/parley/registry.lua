--- parley.registry — Provider registry.
---
--- Maps a parley.VcsInfo (extracted by parley.vcs.detect) to a provider
--- instance by iterating registered ProviderSpecs and calling each spec's
--- detect function.  The first spec whose detect returns non-nil wins; the
--- returned table is forwarded to factory() as its opts argument.
---
--- Design notes:
---   • detect() receives a parley.VcsInfo and returns either:
---       - nil  → this spec does not handle the repo; try the next one.
---       - opts → match; opts is passed straight to factory(opts).
---   • This dual role (match + extract) lets a provider derive the bits it
---     needs (owner/repo/host for GitHub, project/group for GitLab, …) at
---     detect time, so the orchestrator stays provider-agnostic.
---   • First-match wins; registration order is therefore significant.
---   • reset() is provided for test isolation.

local provider_mod = require("parley.provider")

local M = {}

-- ---------------------------------------------------------------------------
-- Type annotations
-- ---------------------------------------------------------------------------

--- @class parley.HealthEntry
--- @field level 'ok'|'info'|'warn'|'error'
--- @field message string

--- @class parley.HealthContext
--- @field vcs_info parley.VcsInfo
--- @field opts table
--- @field config table

--- A self-contained descriptor for one hosting provider.
---
--- @class parley.ProviderSpec
--- @field name    string                                            Human-readable name (e.g. "GitHub")
--- @field detect  fun(vcs_info: parley.VcsInfo): table|nil           Returns factory opts on match, nil on miss
--- @field factory fun(opts: table): parley.Provider                  Creates and returns a provider instance
--- @field health? fun(context: parley.HealthContext): parley.HealthEntry[] Local-only coroutine diagnostics

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
  assert(spec.health == nil or type(spec.health) == "function", "spec.health must be a function when provided")
  table.insert(_specs, spec)
end

--- Find the first registered spec whose detect(vcs_info) returns non-nil,
--- call its factory with that return value, validate the result, and return
--- the provider.
---
--- Returns nil if no spec matches.
--- Raises an error (including spec.name) if the matching factory returns an
--- invalid provider.
---
--- @param vcs_info parley.VcsInfo  Forwarded verbatim to each detect function
--- @return parley.Provider|nil, table|nil
function M.resolve_with_opts(vcs_info)
  assert(type(vcs_info) == "table", "vcs_info must be a table")
  for _, spec in ipairs(_specs) do
    local opts = spec.detect(vcs_info)
    if opts ~= nil then
      assert(
        type(opts) == "table",
        string.format("parley.registry: detect for provider %q must return a table or nil", spec.name)
      )
      local p = spec.factory(opts)
      if not provider_mod.validate(p) then
        error(
          string.format(
            "parley.registry: factory for provider %q returned an invalid provider "
              .. "(required and present optional methods must be functions; display_name must be a nonblank string)",
            spec.name
          ),
          2
        )
      end
      return p, opts
    end
  end
  return nil
end

--- Resolve a validated provider without exposing detection options.
--- @param vcs_info parley.VcsInfo
--- @return parley.Provider|nil
function M.resolve(vcs_info)
  local provider = M.resolve_with_opts(vcs_info)
  return provider
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
