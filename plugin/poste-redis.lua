-- poste-redis.nvim — Redis execution plugin for Poste.
-- Requires poste.nvim (shared infra) on the runtimepath.
local ok, _ = pcall(require, "poste.state")
if not ok then
  vim.notify("poste-redis.nvim requires poste.nvim. Install it first.", vim.log.levels.WARN)
  return
end
require("poste-redis.init").setup({})
