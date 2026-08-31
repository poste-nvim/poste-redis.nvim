--- poste-redis.nvim — Redis execution for the Poste plugin family.
local config = require("poste-redis.config")
local M = {}

function M.setup(opts)
  opts = opts or {}
  config.merge(opts)

  require("poste-redis.highlights").setup()
  vim.api.nvim_create_autocmd("ColorScheme", {
    callback = function() require("poste-redis.highlights").setup() end,
  })

  require("poste-redis.autocmds").setup()
  require("poste-redis.commands").setup()
  require("poste-redis.autocmds").setup_existing_buffers()

  -- M2 P1-6: best-effort parser compile (silent without a C compiler; health
  -- reports it). Deferred so plugin load never blocks on cc.
  vim.schedule(function()
    pcall(function() require("poste-redis.install").ensure_parsers() end)
  end)
end

return M
