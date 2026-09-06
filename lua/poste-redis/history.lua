--- Command history (M1: in-memory, not persisted). Everything that touched
--- redis lands here: .redis executions (runner), dataset cell/row writes
--- (browser/grid_edit), and browser mutations (browser/actions) — batch
--- deletes aggregate into ONE entry (`DEL prefix:*`) instead of one line per
--- key. Toggling opens a sidebar float beside the redis_result panel: the
--- panel is a full-width split, so while the sidebar is open the panel is
--- NARROWED by the sidebar's footprint and the float anchors in the freed
--- columns — the panel's data stays fully visible (width restored on close):
---   j/k   move the selection; the entry's result snapshot renders LIVE into
---         the result panel. Write commands (browser deletes/TTL) have no
---         snapshot — the panel shows a hint instead.
---   <Tab> jump focus to the result panel (sidebar stays open): the preview
---         is a live panel there — move the cursor, select, yank, and `K`
---         shows the entry's raw value detail. <leader>rh returns here.
---   <CR>  activate the entry (panel keeps it) and close the sidebar
---   y     yank the command (`yank` wins over `command` — batch deletes yank
---         a redis-cli pipeline, since a bare `DEL prefix:*` glob is not
---         executable)
---   q/<Esc> close
local constants = require("poste-redis.constants")
local util = require("poste-redis.util")

local M = {}

local history = {}   -- newest last: { command, connection, status, latency_ms, error, lines, value, ts, kind, yank, count }
local max_entries = constants.HISTORY_MAX

local buf = nil
local win = nil
local hl_ns = vim.api.nvim_create_namespace("poste_redis_history")

local SIDEBAR_WIDTH = 42
-- Panel width borrowed by the open sidebar (restored on close).
local panel_orig_width = nil

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
---   lines, value, kind ("exec"|"write"), yank, count, db }
---   value: the raw (transport-truncated) result value — rides the snapshot
---   so `K` in the panel can preview the entry's detail
function M.push(entry)
  history[#history + 1] = {
    command = entry.command or "",
    connection = entry.connection or "",
    status = entry.status or "",
    latency_ms = entry.latency_ms,
    error = entry.error,
    lines = entry.lines or {},
    value = entry.value,
    kind = entry.kind or "exec",
    yank = entry.yank,
    count = entry.count,
    db = entry.db,
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

--- Render entry `idx` into the result panel. Entries carrying the raw value
--- re-render as a REAL result tab — full grid with the floating header, cell
--- navigation, K and yank (a text snapshot can't show the grid header: it
--- lives in a floating window, not in the buffer lines). Entries without a
--- value fall back to the stored text snapshot; write commands (browser
--- mutations) show a hint pointing at `y` instead.
--- @param idx number  1-based into M.list() (newest first)
--- @param enter boolean|nil  false keeps focus where it is (live j/k preview)
function M.activate(idx, enter)
  local e = M.list()[idx]
  if not e then return end
  local buffer = require("poste-redis.buffer")
  if e.value and type(e.value) == "table" and e.value.type then
    local out = require("poste-redis.format").format_result({
      command = e.command,
      status = e.status,
      latency_ms = e.latency_ms,
      error = e.error,
      value = e.value,
    })
    out.meta.connection = e.connection
    out.meta.db = e.db
    if out.kind == "table" then
      out.meta.key = require("poste-redis.parser").key_arg(
        require("poste-redis.parser").command_tokens(out.meta.command or ""))
    end
    buffer.render_tabs({ out }, { render = true, enter = enter and true or false })
    return
  end
  if not e.lines or #e.lines == 0 then
    buffer.render_snapshot({
      "No result snapshot for this entry.",
      "",
      "  " .. tostring(e.command or ""),
      "",
      "Write commands (browser mutations) store no result set —",
      "press y in the history sidebar to yank an executable form.",
    }, {
      command = e.command,
      status = e.status,
      error = e.error,
      value = e.value,
    }, { enter = enter })
    return
  end
  buffer.render_snapshot(e.lines, {
    command = e.command,
    status = e.status,
    latency_ms = e.latency_ms,
    error = e.error,
    value = e.value,
  }, { enter = enter })
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
-- Sidebar float (beside the result panel, which narrows to make room)
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
  -- the selection under the cursor (linked preview target)
  local lnum = vim.api.nvim_win_get_cursor(win)[1]
  if lnum >= 1 and lnum <= #history then
    vim.api.nvim_buf_add_highlight(buf, hl_ns, "PosteRedisHistoryCurrent", lnum - 1, 0, -1)
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
  -- linked preview: the result panel shows the entry under the cursor
  -- (focus stays in the sidebar). Write entries render the hint.
  M.activate(vim.api.nvim_win_get_cursor(win)[1], false)
  refresh()
end

local function activate_and_close()
  if not win or not vim.api.nvim_win_is_valid(win) then return end
  local lnum = vim.api.nvim_win_get_cursor(win)[1]
  if lnum >= 1 and lnum <= M.count() then
    M.activate(lnum)  -- enter: the panel takes focus after the float closes
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
  -- anchor beside the result panel: the panel is a full-width bottom split,
  -- so ANY float over it would cover data — narrow the panel by the sidebar's
  -- footprint and anchor the float in the freed columns (width restored on
  -- close). Skipped when the panel is already too narrow to give up space.
  local buffer = require("poste-redis.buffer")
  if not buffer.is_open() then buffer.show_panel(false) end
  local panel_win = buffer.win()
  if not panel_win then return end

  local panel_h = vim.api.nvim_win_get_height(panel_win)
  local winbar_rows = vim.api.nvim_get_option_value("winbar", { win = panel_win }) ~= "" and 1 or 0
  local height = math.max(2, panel_h - winbar_rows - 3)
  local width = math.max(20, math.min(SIDEBAR_WIDTH, vim.o.columns - 2))

  panel_orig_width = nil
  local panel_w = vim.api.nvim_win_get_width(panel_win)
  if panel_w - (width + 1) >= 20 then
    panel_orig_width = panel_w
    vim.api.nvim_win_set_width(panel_win, panel_w - width - 1)
  end

  buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_buf_set_name(buf, "poste://redis_history")
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  win = vim.api.nvim_open_win(buf, true, {
    relative = "win",
    win = panel_win,
    row = 0,
    col = vim.api.nvim_win_get_width(panel_win),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
  })
  vim.api.nvim_set_option_value("cursorline", true, { win = win })
  -- floats inherit the CURRENT window's options at open time; opened from
  -- the result panel that means winhl=Normal:PosteRedisResultMeta and the
  -- sidebar's text rendered in the panel's gray meta ink
  pcall(vim.api.nvim_set_option_value, "winhl", "Normal:Normal", { win = win })
  local km = { buffer = buf, noremap = true, silent = true }
  vim.keymap.set("n", "j", function() move(1) end, km)
  vim.keymap.set("n", "k", function() move(-1) end, km)
  vim.keymap.set("n", "<Tab>", function() M.focus_panel() end, km)
  vim.keymap.set("n", "<CR>", activate_and_close, km)
  vim.keymap.set("n", "y", yank_and_stay, km)
  vim.keymap.set("n", "q", M.close, km)
  vim.keymap.set("n", "<Esc>", M.close, km)

  refresh()
  set_cursor(1)
end

--- Jump focus to the result panel, keeping the sidebar open: the previewed
--- snapshot is a live panel there — cursor moves, `K` shows the entry's raw
--- value detail, yank works. `<leader>rh` (toggle) returns to the sidebar.
function M.focus_panel()
  local w = require("poste-redis.buffer").win()
  if w and vim.api.nvim_win_is_valid(w) then
    vim.api.nvim_set_current_win(w)
  end
end

function M.toggle()
  -- already open: (re)focus the sidebar instead of closing, so the browse
  -- flow sidebar ⇄ panel (<Tab> out, <leader>rh back) never loses the
  -- selection; closing lives on q/<Esc> inside the sidebar
  M.open()
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
  -- give the panel its columns back
  if panel_orig_width then
    local pw = require("poste-redis.buffer").win()
    if pw and vim.api.nvim_win_is_valid(pw) then
      pcall(vim.api.nvim_win_set_width, pw, panel_orig_width)
    end
    panel_orig_width = nil
  end
end

function M.is_open()
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

--- Sidebar window handle (tests).
function M.win()
  return win
end

--- Sidebar buffer handle (tests).
function M.buf()
  return buf
end

M._test = { build = build, sidebar_width = SIDEBAR_WIDTH }

return M
