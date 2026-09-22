--- Command history (M1: in-memory, not persisted). Everything that touched
--- redis lands here: .redis executions (runner), dataset cell/row writes
--- (browser/grid_edit), and browser mutations (browser/actions) — batch
--- deletes aggregate into ONE entry (`DEL prefix:*`) instead of one line per
--- key. Toggling opens a sidebar beside the redis_result panel as a REAL
--- vertical split of the panel window: a full-width bottom split cannot be
--- narrowed any other way (`nvim_win_set_width` silently no-ops on a frame
--- row without a vertical split), so only frame mechanics free the columns —
--- the panel is narrowed while the sidebar is open and gets its width back
--- automatically on close, its data staying fully visible:
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
---   error: the server's message for a failed run — a string, never a boolean,
---     because replay renders it verbatim (see runner.present).
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
      -- An entry is a whole batch: its `status` is the batch verdict while the
      -- value/error below belong to the FIRST command. Without the flag a batch
      -- whose later command failed would replay as an error block and lose the
      -- result the user actually saw (`runner.on_done` says the same).
      batch = true,
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
    -- A rejected write has no result set, but it does have the server's
    -- reason. The "no snapshot" hint would read as if the entry were lost,
    -- when what the user came looking for is why `RENAME` failed.
    local rejected, err_text = require("poste-redis.format").command_failed(e)
    if rejected then
      buffer.render_snapshot(
        require("poste-redis.format").format_error(err_text, e.command), {
          command = e.command,
          status = e.status,
          error = err_text,
          value = e.value,
        }, { enter = enter })
      return
    end
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
-- Sidebar (beside the result panel as a real split of the panel row)
-----------------------------------------------------------------------

--- An entry counts as failed when it carries an error message OR was pushed
--- with `status == "error"`. The two are not the same: a batch whose later
--- command failed reports status "error" while its stored message is the
--- first (successful) result's — nil. Both the ✗ column and its highlight read
--- this, so the rule lives in one place: `format.command_failed`, which also
--- filters out the message shapes that say nothing (`vim.NIL`, "").
--- The sidebar marks the BATCH, so it must not pass `batch` — only the replay
--- of a first command's value honours that exception.
--- @param e table|nil
--- @return boolean
local function failed(e)
  return require("poste-redis.format").command_failed(e)
end

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
    -- `status` is normalized to "" by push, and "" is truthy in Lua, so the
    -- blank arm needs the explicit comparison: an entry that never reported a
    -- status must not read as a success
    local status = e.status or ""
    local mark = failed(e) and "✗"
      or (e.kind == "write" and "+")
      or (status ~= "" and "✓" or " ")
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
      mark = { 0, #mark },
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
    if span.mark and failed(e) then
      -- the full mark glyph (3 bytes for ✗) — a 1-byte range used to clamp
      -- at the char boundary and color nothing
      vim.api.nvim_buf_add_highlight(buf, hl_ns, "PosteRedisHistoryError",
        offset - 1, span.mark[1], span.mark[2])
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
  -- Anchor beside the result panel: the panel is a full-width bottom split,
  -- so ANY float over it would cover data — and the panel cannot be narrowed
  -- for a float either (`nvim_win_set_width` no-ops on a frame row without a
  -- vertical split). So the sidebar IS the freed columns: a real vertical
  -- split of the panel window. Closing it makes the panel fill its row again
  -- by itself (no width bookkeeping).
  local buffer = require("poste-redis.buffer")
  if not buffer.is_open() then buffer.show_panel(false) end
  local panel_win = buffer.win()
  if not panel_win then return end

  -- cap the sidebar by the columns the panel can actually give up: when a
  -- neighbor split (the key browser column) has already taken most of the
  -- row's width, a full-width sidebar would crush the panel to a sliver
  local width = math.max(20,
    math.min(SIDEBAR_WIDTH, vim.o.columns - 2,
      vim.api.nvim_win_get_width(panel_win) - 21))

  buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  -- `:q` on the sidebar window wipes this scratch buffer, but a crashed
  -- session can leave the name alive; drop the stale one first (same E95
  -- dance as the result panel in buffer.show_panel).
  local stale = vim.fn.bufnr("poste://redis_history")
  if stale ~= -1 then
    pcall(vim.api.nvim_buf_delete, stale, { force = true })
  end
  vim.api.nvim_buf_set_name(buf, "poste://redis_history")
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  vim.api.nvim_set_current_win(panel_win)
  vim.cmd("rightbelow vsplit")
  win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_width(win, width)
  -- a vsplit inherits the panel's window-local options: drop the result
  -- winbar and grid chrome so the sidebar reads as a plain list (the float
  -- needed the same winhl reset for inheriting the panel's gray meta ink).
  -- The panel carries a winbar; reserve the matching row (empty) so the
  -- sidebar's first text row starts where the panel's text does — without
  -- it the sidebar's content sits one row up, on the panel's winbar line.
  vim.api.nvim_set_option_value("winbar", " ", { win = win })
  pcall(vim.api.nvim_set_option_value, "winhl", "Normal:Normal", { win = win })
  vim.api.nvim_set_option_value("number", false, { win = win })
  vim.api.nvim_set_option_value("relativenumber", false, { win = win })
  vim.api.nvim_set_option_value("signcolumn", "no", { win = win })
  vim.api.nvim_set_option_value("foldcolumn", "0", { win = win })
  vim.api.nvim_set_option_value("wrap", false, { win = win })
  vim.api.nvim_set_option_value("spell", false, { win = win })
  vim.api.nvim_set_option_value("colorcolumn", "", { win = win })
  vim.api.nvim_set_option_value("cursorline", true, { win = win })
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
