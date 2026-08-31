--- Redis-specific state (isolated from SQL/HTTP).
--- Loaded by poste-redis.nvim plugin; referenced via require("poste-redis.state").
local M = {}

M.TITLE = "PosteRedis"

M.context = {
  connection = nil,   -- current connection name (from USE directive / selector)
  db = nil,           -- current SELECT db (0 if unset)
}
M.last_response = nil  -- last parsed exec summary/result for statusline (M2)

--- Current connection URL resolved for the active context (password redacted
--- never persisted — lives only in memory).
M.current_url = nil

return M
