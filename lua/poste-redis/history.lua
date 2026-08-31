--- Execution history (M1: in-memory, not persisted). One entry per
--- execution run; toggling opens a float list; <CR> re-renders the stored
--- result snapshot into the panel.
local constants = require("poste-redis.constants")
local config = require("poste-redis.config")
local util = require("poste-redis.util")

local M = {}

local history = {}   -- newest last: { command, connection, status, latency_ms, error, lines, ts }
local max_entries = constants.HISTORY_MAX

local buf = nil
local win = nil
local hl_ns = vim.api.nvim_create_namespace("poste_redis_history")

--- Set the cap (config.history_max).
--- @param n number
function M.set_max_history(n)
  max_entries = n or max_entries
end

--- Trim to the cap.
local function trim()
  if #history > max_entries then
    local excess = #history - max_entries
    for _ = 1, excess do table.remove(history, 1) end
  end
end

--- Push a run into history.
--- @param entry table { command, connection, status, latency_ms, error, lines }
function M.push(entry)
  history[#history + 1] = {
    command = entry.command or "",
    connection = entry.connection or "",
    status = entry.status or "",
    latency_ms = entry.latency_ms,
    error = entry.error,
    lines = entry.lines or {},
    ts = os.time(),
  }
  trim()
end

--- Full list (newest first).
--- @return table[]
function M.list()
  local out = {}
  for i = #history, 1, -1 do out[#out + 1] = history[i] end
  return out
end

function M.count()
  return #history
end

--- Clear all history (tests / :PosteRedisHistoryClear).
function M.clear()
  history = {}
end

--- History index → panel renderer.
--- @param idx number  1-based into M.list() (newest first)
function M.activate(idx)
  local items = M.list()
  local entry = items[idx]
  if not entry then return end
  require("poste-redis.buffer").render_snapshot(entry.lines, {
    command = entry.command,
    status = entry.status,
    latency_ms = entry.latency_ms,
    error = entry.error,
  })
end

-----------------------------------------------------------------------
-- Float list
-----------------------------------------------------------------------

local function build_lines()
  local items = M.list()
  local lines = {}
  for i, e in ipairs(items) do
    local mark = e.error and "✗" or (e.status and "✓" or " ")
    local lat = e.latency_ms and util.format_latency(e.latency_ms) or ""
    lines[#lines + 1] = string.format("%s [%d] %s  %s",
      mark, i, util.truncate_display(e.command, 40), lat)
  end
  if #lines == 0 then lines[1] = "  (no history)" end
  return lines
end

local function refresh()
  if not win or not vim.api.nvim_win_is_valid(win) then return end
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, build_lines())
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.api.nvim_buf_clear_namespace(buf, hl_ns, 0, -1)
  for offset = 0, #history - 1 do
    local e = history[#history - offset]
    if e.error then
      vim.api.nvim_buf_add_highlight(buf, hl_ns, "PosteRedisHistoryError", offset, 0, 1)
    end
  end
end

local function set_cursor(lnum)
  if not win or not vim.api.nvim_win_is_valid(win) then return end
  vim.api.nvim_win_set_cursor(win, { math.max(1, math.min(lnum, math.max(1, #history))), 0 })
end

local function move(rel)
  if not win or not vim.api.nvim_win_is_valid(win) then return end
  local cur = vim.api.nvim_win_get_cursor(win)[1]
  set_cursor(cur + rel)
end

local function activate_and_close()
  if not win or not vim.api.nvim_win_is_valid(win) then return end
  local lnum = vim.api.nvim_win_get_cursor(win)[1]
  if lnum >= 1 and lnum <= M.count() then
    M.activate(lnum)
  end
  M.close()
end

function M.open()
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    return
  end
  local width = math.min(60, vim.o.columns - 4)
  local height = math.min(20, M.count() + 2)
  buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
  win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = math.max(3, height),
    row = math.floor((vim.o.lines - math.max(3, height)) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = "History",
    title_pos = "center",
  })
  vim.api.nvim_set_option_value("cursorline", true, { win = win })
  local km = { buffer = buf, noremap = true, silent = true }
  vim.keymap.set("n", "j", function() move(1) end, km)
  vim.keymap.set("n", "k", function() move(-1) end, km)
  vim.keymap.set("n", "<CR>", activate_and_close, km)
  vim.keymap.set("n", "q", M.close, km)
  vim.keymap.set("n", "<Esc>", M.close, km)
  refresh()
  set_cursor(1)
end

function M.toggle()
  if win and vim.api.nvim_win_is_valid(win) then
    M.close()
  else
    M.open()
  end
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

function M.is_open()
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

M._test = { build_lines = build_lines }

return M
