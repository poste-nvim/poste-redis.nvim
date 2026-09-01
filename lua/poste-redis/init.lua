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

  -- P2-4: completion source (blink.cmp). Register when blink is present;
  -- retried on InsertEnter if it loads later (poste-db register pattern).
  local ok = pcall(require("poste-redis.completion.register").register)
  if not ok then
    local group = vim.api.nvim_create_augroup("PosteRedisCmpRegister", { clear = true })
    vim.api.nvim_create_autocmd("InsertEnter", {
      group = group,
      once = true,
      callback = function()
        pcall(require("poste-redis.completion.register").register)
        pcall(vim.api.nvim_del_augroup_by_name, "PosteRedisCmpRegister")
      end,
    })
  end

  -- M2 P1-6: best-effort parser compile (silent without a C compiler; health
  -- reports it). Deferred so plugin load never blocks on cc.
  vim.schedule(function()
    pcall(function() require("poste-redis.install").ensure_parsers() end)
  end)
end

return M
