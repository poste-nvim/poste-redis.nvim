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
      -- M2 P1-6: enable tree-sitter highlighting when the compiled parser is
      -- available; otherwise the M1 regex syntax stays active (fallback).
      local treesitter = require("poste-redis.treesitter")
      if treesitter.parser_available() then
        treesitter.enable(args.buf)
      end
      buffer_setup.setup_buffer_keymaps(args.buf)
    end,
  })
end

--- Wire up buffers already open when setup() runs.
function M.setup_existing_buffers()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local ft = vim.api.nvim_get_option_value("filetype", { buf = buf })
    if ft == "poste_redis" then
      buffer_setup.setup_buffer_keymaps(buf)
    end
  end
end

return M
