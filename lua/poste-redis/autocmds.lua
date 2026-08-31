--- FileType wiring for poste_redis buffers: syntax + keymaps + existing
--- buffers at setup time.
local config = require("poste-redis.config")
local buffer_setup = require("poste-redis.buffer_setup")

local M = {}

function M.setup()
  local group = vim.api.nvim_create_augroup("PosteRedis", { clear = true })

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "poste_redis",
    callback = function(args)
      -- M2: try to register the tree-sitter grammar when present; regex
      -- syntax/poste_redis.vim remains the M1 fallback and keeps working.
      pcall(vim.treesitter.language.register, "poste_redis", "poste_redis")
      buffer_setup.setup_buffer_keymaps(args.buf)
    end,
  })
end

--- Wire up buffers already open when setup() runs.
function M.setup_existing_buffers()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local ft = vim.api.nvim_buf_get_option(buf, "filetype")
    if ft == "poste_redis" then
      buffer_setup.setup_buffer_keymaps(buf)
    end
  end
end

return M
