--- Redis plugin constants.
local M = {}

M.PLUGIN_TITLE = "PosteRedis"
M.TITLE = M.PLUGIN_TITLE

-- vendored from poste.nvim@5b3759e lua/poste/constants.lua — the entries
-- consumed by this plugin's vendored indicators.lua (family dissolution)
M.SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
M.SPINNER_INTERVAL_MS = 100
M.INDICATOR_NS_NAME = "poste_indicator"
M.SIGN_GROUP_NAME = "poste_sg_4a7f"

--- Result panel split: share of the editor height at creation/on resize.
M.RESULT_HEIGHT_RATIO = 0.4
M.RESULT_MIN_HEIGHT = 4

--- Float preview (K on raw JSON) dimensions.
M.FLOAT_WIDTH_RATIO = 0.7
M.FLOAT_MAX_WIDTH = 120
M.FLOAT_HEIGHT_RATIO = 0.6

--- Large-value truncation threshold (bytes) before the panel shows a
--- summary instead of the raw payload. Mirrors config.preview_max_bytes.
M.MAX_PREVIEW_BYTES = 65536

--- Binary payloads: bytes previewed in the hex digest line (front bytes).
M.BINARY_PREVIEW_BYTES = 64

--- SCAN batch size for browser/cursor-key enumeration (config.scan_count).
M.SCAN_COUNT = 500

--- History (in-memory) cap.
M.HISTORY_MAX = 200

--- Floating-chrome z-index tiers. The browser's pinned header overlay sits
--- BELOW every result/history float, so an overlap never lets browser chrome
--- paint over result/history chrome. (The result panel and history sidebar
--- themselves are real split windows — floats always layer above normal
--- windows, which is why the browser overlay must also never outgrow its
--- anchor; shared poste.nvim dialogs own 49+.)
M.ZINDEX_BROWSER = 40
M.ZINDEX_RESULT = 45

--- Connection URL scheme detection.
--- @param url string
--- @return boolean
function M.is_redis_url(url)
  return type(url) == "string" and (url:sub(1, 8) == "redis://" or url:sub(1, 9) == "rediss://")
end

--- Default redis database count (redis.conf `databases 16`). The browser's
--- db picker and the DBSIZE probe iterate 0..REDIS_DB_COUNT-1; a server
--- configured with more dbs simply is not listed beyond this.
M.REDIS_DB_COUNT = 16

--- Dangerous commands (P2 blacklist). M1: parser flags these so the result
--- panel shows a yellow warning; full interception lands in M3.
M.DANGEROUS_COMMANDS = {
  FLUSHALL = true,
  FLUSHDB = true,
  SHUTDOWN = true,
  ["CONFIG"] = true, -- CONFIG SET/RESETSTAT
}

--- True when the command is blacklisted. Only the first token is inspected,
--- so `CONFIG SET save ''` matches the `CONFIG` entry.
--- @param cmd string|nil
--- @return boolean
function M.is_dangerous_command(cmd)
  if type(cmd) ~= "string" or cmd == "" then return false end
  local name = cmd:match("^%s*(%S+)")
  if not name then return false end
  return M.DANGEROUS_COMMANDS[name:upper()] == true
end

return M
