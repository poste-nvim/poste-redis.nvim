--- Source-buffer keymaps for `poste_redis` buffers (the .redis file).
--- Bound once per buffer on FileType / setup_existing_buffers.
local config = require("poste-redis.config")
local constants = require("poste-redis.constants")

local M = {}

--- Show the keymap help for a source buffer in a float.
local function show_help(buf)
  local ui = require("poste-redis.ui")
  local items = {
    "poste-redis source keymaps:",
    "  " .. config.format_keymap("redis_source", "run") .. "   run command under cursor / selection",
    "  " .. config.format_keymap("redis_source", "reveal_key") .. "   reveal the command's key in the browser tree",
    "  " .. config.format_keymap("redis_source", "history") .. "   open request history",
    "  " .. config.format_keymap("redis_source", "show_doc") .. "   show command documentation (K again focuses)",
    "  " .. config.format_keymap("redis_source", "trigger_completion") .. "   trigger completion",
    "  " .. config.format_keymap("redis_source", "help") .. "   this help",
    "",
    "poste-redis result panel keymaps:",
    "  " .. config.format_keymap("redis_result", "close") .. "   close panel",
    "  " .. config.format_keymap("redis_result", "next_tab") .. " / " .. config.format_keymap("redis_result", "prev_tab") .. "   switch result tabs",
    "  " .. config.format_keymap("redis_result", "preview_cell") .. "   preview cell / raw value",
    "  " .. config.format_keymap("redis_result", "yank_cell") .. " / " .. config.format_keymap("redis_result", "yank_column") .. "   yank cell / column",
    "  " .. config.format_keymap("redis_result", "prev_page") .. " / " .. config.format_keymap("redis_result", "next_page") .. "   previous / next page",
    "  " .. config.format_keymap("redis_result", "sort_column") .. "   sort by the cursor column (none → desc → asc → none)",
    "  " .. config.format_keymap("redis_result", "show_search") .. "   search in results",
  }
  ui.centered_float(items, {
    title = "poste-redis help",
    width = math.min(72, vim.o.columns - 4),
    height = math.min(#items + 2, vim.o.lines - 4),
  })
  vim.cmd.redraw()
end

--- Bind source-buffer keymaps.
--- @param buf number
function M.setup_buffer_keymaps(buf)
  require("poste-redis.winbar").attach(buf)
  local runner = require("poste-redis.runner")
  local km = { buffer = buf, noremap = true, silent = true }

  local k = config.get_keymap("redis_source", "run", "<CR>")
  if k then
    vim.keymap.set("n", k, function() runner.run_selection("cursor") end, km)
    vim.keymap.set("v", k, function()
      -- Capture the selection while it is still live: inside a visual-mode
      -- callback the '< '>' marks are not readable until visual mode ends, so
      -- relying on parser.visual_entries' mark fallback dropped the whole
      -- range and only the cursor's statement ran. poste-db reads the marks
      -- synchronously at the top of the callback for the same reason.
      local range = {
        start_line = vim.fn.line("'<"),
        end_line = vim.fn.line("'>"),
      }
      runner.run_selection("visual", range)
    end, km)
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
  k = config.get_keymap("redis_source", "show_doc", "K")
  if k then
    vim.keymap.set("n", k, function()
      require("poste-redis.doc").show_command_doc()
    end, km)
  end
  -- gd: reveal the command's key in the browser tree. The jump is scoped by
  -- the command's own context — the nearest USE above + SELECT at/above the
  -- cursor (context.file_context), never the global context.
  k = config.get_keymap("redis_source", "reveal_key", "gd")
  if k then
    vim.keymap.set("n", k, function()
      local parser = require("poste-redis.parser")
      local lnum = vim.fn.line(".")
      local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
      local tokens = parser.command_tokens(line)
      if not tokens or #tokens < 2 or tokens[1]:upper() == "USE" or tokens[1]:upper() == "SELECT" then
        vim.notify("No key to reveal on this line", vim.log.levels.INFO,
          { title = constants.TITLE })
        return
      end
      local ctx = require("poste-redis.context").file_context(buf, lnum)
      require("poste-redis.browser.init").reveal({
        key = tokens[2],
        connection = ctx.connection,
        db = ctx.db or 0,
      })
    end, km)
  end
end

return M
