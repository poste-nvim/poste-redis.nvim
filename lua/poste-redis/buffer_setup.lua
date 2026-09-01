--- Source-buffer keymaps for `poste_redis` buffers (the .redis file).
--- Bound once per buffer on FileType / setup_existing_buffers.
local config = require("poste-redis.config")

local M = {}

--- Show the keymap help for a source buffer in a float.
local function show_help(buf)
  local constants = require("poste-redis.constants")
  local items = {
    "poste-redis source keymaps:",
    "  " .. config.format_keymap("redis_source", "run") .. "   run command under cursor / selection",
    "  " .. config.format_keymap("redis_source", "history") .. "   open request history",
    "  " .. config.format_keymap("redis_source", "trigger_completion") .. "   trigger completion",
    "  " .. config.format_keymap("redis_source", "help") .. "   this help",
    "",
    "poste-redis result panel keymaps:",
    "  " .. config.format_keymap("redis_result", "close") .. "   close panel",
    "  " .. config.format_keymap("redis_result", "next_tab") .. " / " .. config.format_keymap("redis_result", "prev_tab") .. "   switch result tabs",
    "  " .. config.format_keymap("redis_result", "preview_raw") .. "   preview raw JSON",
    "  " .. config.format_keymap("redis_result", "yank") .. "   yank current result",
  }
  local width = math.min(72, vim.o.columns - 4)
  local height = #items + 2
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, items)
  vim.api.nvim_buf_set_option(b, "modifiable", false)
  vim.api.nvim_buf_set_option(b, "bufhidden", "wipe")
  local w = vim.api.nvim_open_win(b, true, {
    relative = "editor",
    width = width,
    height = math.min(height, vim.o.lines - 4),
    row = math.floor((vim.o.lines - math.min(height, vim.o.lines - 4)) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = "poste-redis help",
    title_pos = "center",
  })
  local km = { buffer = b, noremap = true, silent = true }
  vim.keymap.set("n", "q", function() pcall(vim.api.nvim_win_close, w, true) end, km)
  vim.keymap.set("n", "<Esc>", function() pcall(vim.api.nvim_win_close, w, true) end, km)
  vim.cmd.redraw()
end

--- Bind source-buffer keymaps.
--- @param buf number
function M.setup_buffer_keymaps(buf)
  local runner = require("poste-redis.runner")
  local km = { buffer = buf, noremap = true, silent = true }

  local k = config.get_keymap("redis_source", "run", "<CR>")
  if k then
    vim.keymap.set("n", k, function() runner.run_selection("cursor") end, km)
    vim.keymap.set("v", k, function() runner.run_selection("visual") end, km)
  end
  k = config.get_keymap("redis_source", "history", "<leader>rh")
  if k then
    vim.keymap.set("n", k, function() require("poste-redis.history").toggle() end, km)
  end
  k = config.get_keymap("redis_source", "help", "g?")
  if k then
    vim.keymap.set("n", k, function() show_help(buf) end, km)
  end
  k = config.get_keymap("redis_source", "trigger_completion", "<C-Space>")
  if k then
    vim.keymap.set("i", k, function()
      pcall(function() require("poste-redis.completion.adapter").show() end)
    end, { buffer = buf, noremap = true, silent = true, desc = "Trigger redis completion" })
  end
end

return M
