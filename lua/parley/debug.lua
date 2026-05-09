--- parley.debug — optional trace logging to a file.
---
--- Tracing is disabled by default. Call tracing_enable(true) from setup()
--- to activate; the log file is truncated on each enable so every session
--- starts with a clean file.
---
--- Log file location: stdpath("log")/parley.log
---
--- Testability:
---   Override M._write (fun(path: string, line: string): nil) in tests
---   to capture output without touching the filesystem.

local M = {}

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

--- @type boolean
M._enabled = false

--- Injectable seam: replace with a spy in tests.
--- @type fun(path: string, line: string): nil | nil
M._write = nil

local LOG_PATH = vim.fn.stdpath("log") .. "/parley.log"

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Enable or disable trace logging.
--- Enabling truncates the log file so each session starts clean.
---
--- @param on boolean
function M.tracing_enable(on)
  M._enabled = on
  if on then
    local f = io.open(LOG_PATH, "w")
    if f then
      f:close()
    end
  end
end

--- Append a timestamped trace line to the log file (when tracing is enabled).
---
--- @param tag string   Short module identifier, e.g. "github.provider"
--- @param msg string   Free-form message
function M.trace(tag, msg)
  if not M._enabled then
    return
  end
  local line = os.date("%H:%M:%S") .. " [" .. tag .. "] " .. msg .. "\n"
  if M._write then
    M._write(LOG_PATH, line)
    return
  end
  local f = io.open(LOG_PATH, "a")
  if not f then
    return
  end
  f:write(line)
  f:close()
end

return M
