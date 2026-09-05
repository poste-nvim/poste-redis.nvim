--- Command history (M1: in-memory, not persisted). Everything that touched
--- redis lands here: .redis executions (runner), dataset cell/row writes
--- (browser/grid_edit), and browser mutations (browser/actions) — batch
--- deletes aggregate into ONE entry (`DEL prefix:*`) instead of one line per
--- key. Toggling opens a float list: command left-aligned + highlighted,
--- execution time right-aligned in gray; `y` yanks the command (`yank`
--- wins over `command` — batch deletes yank a redis-cli pipeline, since a
--- bare `DEL prefix:*` glob is not executable), <CR> re-renders a stored
--- result snapshot (exec runs only).
local constants = require("poste-redis.constants")
local util = require("poste-redis.util")

local M = {}

local history = {}   -- newest last: { command, connection, status, latency_ms, error, lines, ts, kind, yank, count }
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

--- Push a run / write into history.
--- @param entry table { command, connection, status, latency_ms, error,
---   lines, kind ("exec"|"write"), yank (executable form for `y`), count }
function M.push(entry)
  history[#history + 1] = {
    command = entry.command or "",
    connection = entry.connection or "",
    status = entry.status or "",
    latency_ms = entry.latency_ms,
    error = entry.error,
    lines = entry.lines or {},
    kind = entry.kind or "exec",
    yank = entry.yank,
    count = entry.count,
    ts = entry.ts or os.time(),
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

--- History index → panel renderer. Entries without a stored snapshot (write
--- commands) have nothing to re-render — point at `y` instead.
--- @param idx number  1-based into M.list() (newest first)
function M.activate(idx)
  local items = M.list()
  local entry = items[idx]
  if not entry then return end
  if not entry.lines or #entry.lines == 0 then
    vim.notify("This entry has no result snapshot (write command) — press y to yank it",
      vim.log.levels.INFO, { title = constants.TITLE })
    return
  end
  require("poste-redis.buffer").render_snapshot(entry.lines, {
    command = entry.command,
    status = entry.status,
    latency_ms = entry.latency_ms,
    error = entry.error,
  })
end

--- Yank an entry's command (the executable `yank` form when present).
--- @param idx number  1-based into M.list()
function M.yank(idx)
  local e = M.list()[idx]
  if not e then return end
  local text = e.yank or e.command
  vim.fn.setreg('"', text)
  pcall(vim.fn.setreg, "+", text)
  vim.notify("Yanked: " .. util.truncate_display(text, 60),
    vim.log.levels.INFO, { title = constants.TITLE })
end

-----------------------------------------------------------------------
-- Float list
-----------------------------------------------------------------------

--- Render the float body: `✓ <command padded>  <HH:MM:SS>` — the command
--- left-aligned (truncated to fit), the time pinned to the right edge.
--- @param width number  float width (display cells)
--- @return string[] lines, table[] spans  per-line byte spans for extmarks
---   { cmd = { start, end_ }, time = { start, end_ } } (nil when no history)
local function build(width)
  width = width or 60
  local items = M.list()
  local lines, spans = {}, {}
  for i, e in ipairs(items) do
    local mark = e.error and "✗" or (e.kind == "write" and "+" or (e.status and "✓" or " "))
    local time = os.date("%H:%M:%S", e.ts or os.time())
    local cmd_max = width - 12  -- mark+space (2) + gap (1) + time (8) + margin (1)
    local cmd = util.truncate_display(e.command or "", cmd_max)
    local pad = math.max(1, width - 8 - 2 - util.display_width(cmd))
    local line = mark .. " " .. cmd .. string.rep(" ", pad) .. time
    lines[#lines + 1] = line
    -- extmark spans are BYTE ranges: the ✓/✗ mark is multibyte, so the cmd
    -- start walks past its bytes; the time is the line's last 8 bytes
    local cmd_s = #mark + 1
    spans[#spans + 1] = {
      cmd = { cmd_s, cmd_s + #cmd },
      time = { #line - 8, #line },
    }
  end
  if #lines == 0 then lines[1] = "  (no history)" end
  return lines, spans
end

local function refresh()
  if not win or not vim.api.nvim_win_is_valid(win) then return end
  local width = vim.api.nvim_win_get_width(win)
  local lines, spans = build(width)
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.api.nvim_buf_clear_namespace(buf, hl_ns, 0, -1)
  for offset, span in ipairs(spans) do
    local e = history[#history - (offset - 1)]
    if e and e.error then
      vim.api.nvim_buf_add_highlight(buf, hl_ns, "PosteRedisHistoryError", offset - 1, 0, 1)
    end
    if span.cmd then
      vim.api.nvim_buf_add_highlight(buf, hl_ns, "PosteRedisHistoryCmd",
        offset - 1, span.cmd[1], span.cmd[2])
    end
    if span.time then
      vim.api.nvim_buf_add_highlight(buf, hl_ns, "PosteRedisHistoryTime",
        offset - 1, span.time[1], span.time[2])
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

local function yank_and_stay()
  if not win or not vim.api.nvim_win_is_valid(win) then return end
  local lnum = vim.api.nvim_win_get_cursor(win)[1]
  if lnum >= 1 and lnum <= M.count() then
    M.yank(lnum)
  end
end

function M.open()
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    return
  end
  local ui = require("poste-redis.ui")
  win, buf = ui.centered_float({ "" }, {
    title = "History",
    width = math.min(60, vim.o.columns - 4),
    height = math.max(3, math.min(20, M.count() + 2)),
    cursorline = true,
    keymaps = {
      { key = "j", fn = function() move(1) end },
      { key = "k", fn = function() move(-1) end },
      { key = "<CR>", fn = activate_and_close },
      { key = "y", fn = yank_and_stay },
      { key = "q", fn = M.close },
      { key = "<Esc>", fn = M.close },
    },
  })
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

M._test = { build = build }

return M
