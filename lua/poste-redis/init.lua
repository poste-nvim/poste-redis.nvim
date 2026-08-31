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
end

return M
