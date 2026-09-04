--- Source-buffer context winbar: shows the effective USE/SELECT context at
--- the cursor inside a .redis buffer (connection [+ db]), repainted on cursor
--- move so "which context <CR> will execute in" is always visible at the top
--- of the edit window. Color comes from the connection's connections.toml
--- entry (get_ctx_color); a raw URL falls back to plain text. Gated behind
--- config.config.source_winbar — buffer_setup attaches only when enabled.
local config = require("poste-redis.config")
local context = require("poste-redis.context")
local util = require("poste-redis.util")

local M = {}

local attached = {}

local esc = util.escape_winbar

--- Recompute + paint the winbar for a window showing a .redis buffer.
--- @param win number|nil default current window
function M.update(win)
  win = win or vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(win) then return end
  local ctx = context.resolve(win)
  local text = context.display(ctx)
  local bar = " "
  if text ~= "" then
    local ok_st, statusline = pcall(require, "poste-redis.statusline")
    local hl = ok_st and statusline.get_ctx_color(ctx.connection) or nil
    local label = esc(text)
    bar = hl and ("%#" .. hl .. "# " .. label .. " %*") or (" " .. label .. " ")
  end
  pcall(vim.api.nvim_set_option_value, "winbar", bar, { win = win })
end

--- Attach the winbar + live refresh to a poste_redis buffer. No-op when
--- disabled in config or already attached. Buffer numbers never repeat in a
--- session, so `attached[buf]` is a safe once-guard.
--- @param buf number
function M.attach(buf)
  if not config.config.source_winbar then return end
  if not vim.api.nvim_buf_is_valid(buf) or attached[buf] then return end
  attached[buf] = true
  local group = vim.api.nvim_create_augroup("PosteRedisSourceWinbar" .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "CursorMoved", "WinEnter", "BufEnter" }, {
    group = group,
    buffer = buf,
    callback = function()
      -- only the window the cursor is in repaints; others catch up on WinEnter
      M.update()
    end,
  })
  -- paint immediately so the context shows before the first cursor move
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    M.update(win)
  end
end

M._test = {
  update = M.update,
  attached = attached,
}

return M