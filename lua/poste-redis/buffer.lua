--- M1 result panel (EXECUTION-PLAN D2): a single scratch buffer
--- `poste://redis_result` in a bottom split, one tab per executed command.
--- No dataset grid — a compact redis-cli-style text block per tab, switched
--- with <Tab>/<S-Tab>, closed with q, raw JSON previewed with K.
local config = require("poste-redis.config")
local constants = require("poste-redis.constants")
local format = require("poste-redis.format")
local util = require("poste-redis.util")

local M = {}

local buf = nil
local win = nil
local tabs = {}          -- { { lines = string[], meta = table }, ... }
local active = 1         -- 1-based
local last_value = nil   -- current tab's raw value for K preview

-----------------------------------------------------------------------
-- Float preview (K) — simple centered float, mirroring poste-ai's
-- nav_preview pattern without cross-satellite requires.
-----------------------------------------------------------------------

local function preview_float(lines, title)
  local width = math.min(
    constants.FLOAT_MAX_WIDTH,
    math.floor(vim.o.columns * constants.FLOAT_WIDTH_RATIO)
  )
  local height = math.min(
    math.floor(vim.o.lines * constants.FLOAT_HEIGHT_RATIO),
    math.max(6, #lines + 2)
  )
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(b, "bufhidden", "wipe")
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(b, "modifiable", false)
  local w = vim.api.nvim_open_win(b, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = title or "preview",
    title_pos = "center",
  })
  local km = { buffer = b, noremap = true, silent = true }
  vim.keymap.set("n", "q", function() pcall(vim.api.nvim_win_close, w, true) end, km)
  vim.keymap.set("n", "<Esc>", function() pcall(vim.api.nvim_win_close, w, true) end, km)
end

--- Show the raw JSON of the current tab's value in a float.
function M.preview_raw()
  if not last_value then
    vim.notify("No result value to preview", vim.log.levels.INFO, { title = constants.TITLE })
    return
  end
  local lines = {}
  for line in format.preview_json(last_value):gmatch("[^\n]+") do
    lines[#lines + 1] = line
  end
  local meta = tabs[active] and tabs[active].meta
  preview_float(lines, (meta and meta.command) or "raw JSON")
end

--- Yank the current tab's rendered lines.
function M.yank_current()
  if not tabs[active] then return end
  vim.fn.setreg('"', table.concat(tabs[active].lines, "\n"))
  vim.notify("Yanked result", vim.log.levels.INFO, { title = constants.TITLE })
end

-----------------------------------------------------------------------
-- Panel state
-----------------------------------------------------------------------

function M.is_open()
  return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
    and win ~= nil and vim.api.nvim_win_is_valid(win)
end

function M.tab_count()
  return #tabs
end

-----------------------------------------------------------------------
-- Render
-----------------------------------------------------------------------

--- Render the active tab into the buffer + winbar.
local function render_active()
  if not M.is_open() then return end
  local tab = tabs[active]
  local lines = tab and tab.lines or { "" }
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  local bar_parts = {}
  if #tabs > 1 then
    bar_parts[#bar_parts + 1] = ("%d/%d"):format(active, #tabs)
  end
  local meta = tab and tab.meta
  local status = meta and format.status_summary(meta) or ""
  if status ~= "" then
    bar_parts[#bar_parts + 1] = status
  end
  local cmd = meta and meta.command or ""
  if cmd ~= "" then
    bar_parts[#bar_parts + 1] = cmd
  end
  local danger = meta and format.is_dangerous_command(meta.command or "")
  local hl = meta and meta.error and "PosteRedisResultError"
    or (danger and "PosteRedisResultWarning")
    or "PosteRedisResultOk"
  local bar = table.concat(bar_parts, "  ·  ")
  vim.api.nvim_set_option_value("winbar", bar, { win = win })
  pcall(vim.api.nvim_set_option_value, "winhl", "Normal:PosteRedisResultMeta", { win = win })
end

--- Store + optionally render a fresh result list.
--- @param results table[]  result events (or { type="result", error=... } stubs)
--- @param opts table { src_buf, connection, render = boolean }
function M.render(results, opts)
  opts = opts or {}
  tabs = {}
  active = 1
  last_value = nil
  for _, ev in ipairs(results or {}) do
    local out = format.format_result(ev)
    tabs[#tabs + 1] = out
    if out.meta.dangerous then
      vim.notify("Dangerous command: " .. out.meta.command, vim.log.levels.WARN,
        { title = constants.TITLE })
    end
  end
  if #tabs == 0 then
    tabs = { { lines = { "(no results)" }, meta = {} } }
  end
  last_value = tabs[active].meta.value
  if opts.render ~= false then
    M.show_panel()
    render_active()
  end
end

--- Render a pre-formatted snapshot (history replay) as the single tab.
--- Opens the panel if needed.
--- @param lines string[]
--- @param meta table|nil
function M.render_snapshot(lines, meta)
  meta = meta or {}
  tabs = { { lines = lines or { "" }, meta = meta } }
  active = 1
  last_value = meta.value
  M.show_panel()
  render_active()
end

-----------------------------------------------------------------------
-- Window management
-----------------------------------------------------------------------

--- Open (or re-focus) the panel in a bottom horizontal split.
function M.show_panel()
  if M.is_open() then
    pcall(vim.api.nvim_set_current_win, win)
    return
  end
  buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.api.nvim_buf_set_name(buf, "poste://redis_result")
  vim.bo[buf].filetype = "poste_redis_result"

  local height = math.max(
    constants.RESULT_MIN_HEIGHT,
    math.floor(vim.o.lines * constants.RESULT_HEIGHT_RATIO)
  )
  win = vim.api.nvim_open_win(buf, true, {
    split = "below",
    height = height,
  })

  local km = { buffer = buf, noremap = true, silent = true }
  local k = config.get_keymap("redis_result", "close", "q")
  if k then vim.keymap.set("n", k, function() M.close() end, km) end
  k = config.get_keymap("redis_result", "next_tab", "<Tab>")
  if k then vim.keymap.set("n", k, function() M.next_tab() end, km) end
  k = config.get_keymap("redis_result", "prev_tab", "<S-Tab>")
  if k then vim.keymap.set("n", k, function() M.prev_tab() end, km) end
  k = config.get_keymap("redis_result", "preview_raw", "K")
  if k then vim.keymap.set("n", k, function() M.preview_raw() end, km) end
  k = config.get_keymap("redis_result", "yank", "yy")
  if k then vim.keymap.set("n", k, function() M.yank_current() end, km) end
end

function M.next_tab()
  if #tabs < 2 then return end
  active = active + 1
  if active > #tabs then active = 1 end
  last_value = tabs[active].meta.value
  render_active()
end

function M.prev_tab()
  if #tabs < 2 then return end
  active = active - 1
  if active < 1 then active = #tabs end
  last_value = tabs[active].meta.value
  render_active()
end

function M.close()
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  win = nil
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  buf = nil
end

--- Buffer/window handles for tests.
function M.buf()
  return buf
end

function M.win()
  return win
end

function M._tabs()
  return tabs
end

return M
