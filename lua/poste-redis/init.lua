--- poste-redis.nvim — Redis execution for the Poste plugin family.
local config = require("poste-redis.config")
local M = {}

function M.setup(opts)
  opts = opts or {}
  config.merge(opts)

  require("poste-redis.highlights").setup()
  -- named augroup with clear: a second setup() (re-merge opts) must not
  -- stack another handler — each would re-apply highlights on ColorScheme,
  -- and every nvim_set_hl invalidates highlighting (full redraws)
  local cs_group = vim.api.nvim_create_augroup("PosteRedisColorScheme", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = cs_group,
    callback = function() require("poste-redis.highlights").setup() end,
  })

  require("poste-redis.autocmds").setup()
  require("poste-redis.commands").setup()

  -- Shared poste binary (vendored installer, family dissolution): make sure
  -- it is available once per session. vim.g.poste_binary keeps its
  -- first-class override role (a dev/worktree build never triggers a
  -- release download).
  if not vim.g.poste_redis_setup_done then
    vim.g.poste_redis_setup_done = true
    require("poste-redis.install_binary").ensure()
  end

  -- context in the statusline (mini.statusline / lualine), colored per
  -- connection via connections.toml `color`; opt out with statusline = false
  if opts.statusline ~= false then
    require("poste-redis.statusline").setup()
  end

  -- Optional AI chat integration (poste-ai.nvim). Silent when absent; the
  -- registration is retried on :PosteRedisChat in case poste-ai loads later.
  pcall(function() require("poste-redis.ai").register() end)
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
