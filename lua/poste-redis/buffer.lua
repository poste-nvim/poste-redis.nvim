--- M1 result panel (EXECUTION-PLAN D2) + table grid (poste-db dataset style).
---
--- A single scratch buffer `poste://redis_result` in a bottom split, one tab
--- per executed command. Scalars (string/error/binary/...) render as a compact
--- text block; Set/List/Hash/Zset render as a `│`-separated table grid with a
--- floating fixed header, scrollable body, pagination, cell navigation,
--- search, and yank. Grid features are only active on table tabs — text tabs
--- keep the old redis-cli-style block.
---
--- This file is the public facade: panel/window lifecycle, tab switching,
--- refresh, and the `redis_result` keymaps. The internals live in `buffer/` —
--- `state` (shared mutable panel state), `view` (all drawing), `search`,
--- `pager`, `preview`, `yank`.
local config = require("poste-redis.config")
local constants = require("poste-redis.constants")
local format = require("poste-redis.format")

local state = require("poste-redis.buffer.state")
local view = require("poste-redis.buffer.view")
local pager = require("poste-redis.buffer.pager")
local search = require("poste-redis.buffer.search")
local preview = require("poste-redis.buffer.preview")
local yank = require("poste-redis.buffer.yank")
local sort = require("poste-redis.buffer.sort")

local M = {}

local scroll_autocmd_id = nil
-- Forward declaration (Lua pitfall): show_panel binds the keymaps last, but
-- setup_keymaps is defined after it.
local setup_keymaps

------------------------------------------------------------------------
-- Panel state
------------------------------------------------------------------------

function M.is_open()
  return state.is_open()
end

function M.tab_count()
  return #state.tabs
end

--- The active tab object.
function M.active_tab()
  return state.tabs[state.active]
end

------------------------------------------------------------------------
-- TTL probe (winbar countdown)
------------------------------------------------------------------------

--- Countdown timer handle for the active tab's TTL (nil = not running).
--- uv timers fire in a fast context, so the tick is schedule_wrap'd — the
--- complement of the AGENTS.md "no vim.schedule in job callbacks" rule.
local ttl_timer = nil

local function stop_ttl_timer()
  if ttl_timer then
    pcall(function(t)
      t:stop()
      t:close()
    end, ttl_timer)
    ttl_timer = nil
  end
end

--- Resolve a meta.connection entry (name or URL) to a redis URL.
--- @param conn_name string
--- @return string|nil url, string|nil err
local function resolve_connection_url(conn_name)
  if constants.is_redis_url(conn_name) then return conn_name, nil end
  local connections = require("poste-redis.connections")
  return connections.resolve_redis_url(conn_name)
end

local fetch_ttl  -- forward declaration: the expiry tick re-probes

--- Tick the active tab's TTL down once a second and repaint the winbar.
--- At zero, re-probe: the key either expired (part disappears) or its TTL
--- was extended (countdown restarts).
local function start_ttl_countdown()
  stop_ttl_timer()
  ttl_timer = vim.loop.new_timer()
  ttl_timer:start(1000, 1000, vim.schedule_wrap(function()
    local tab = state.tabs[state.active]
    if not tab or type(tab.ttl) ~= "number" or tab.ttl <= 0 then
      stop_ttl_timer()
      return
    end
    tab.ttl = tab.ttl - 1
    view.update_winbar()
    if tab.ttl <= 0 then fetch_ttl() end
  end))
end

--- Best-effort `TTL <key>` probe for the active tab: needs a recorded
--- connection and a key-ish command (2nd token). -1 (persistent) / -2
--- (missing key) / errors display nothing. Fired after every tab render;
--- the winbar part itself is drawn by view.update_winbar from tab.ttl.
function fetch_ttl()
  stop_ttl_timer()
  local tab = state.tabs[state.active]
  local conn_name = tab and tab.meta and tab.meta.connection
  local cmd = tab and tab.meta and tab.meta.command
  if not conn_name or conn_name == "" or not cmd or cmd == "" then return end
  local ok, tokens = pcall(require("poste-redis.parser").command_tokens, cmd)
  if not ok or type(tokens) ~= "table" or #tokens < 2 then return end
  local url = resolve_connection_url(conn_name)
  if not url then return end
  local session_conn = require("poste-redis.session_conn")
  local dispatched = session_conn.execute(url, { "TTL", tokens[2] }, {
    on_response = function(ev)
      if state.tabs[state.active] ~= tab then return end  -- stale probe
      local n = ev.value and ev.value.value
      if type(n) ~= "number" or n < 0 then return end
      tab.ttl = n
      view.update_winbar()
      start_ttl_countdown()
    end,
    on_error = function() end,  -- best effort: the result itself still shows
  }, nil, { db = tab.meta.db })
  if dispatched ~= "dispatched" then stop_ttl_timer() end
end

------------------------------------------------------------------------
-- Refresh
------------------------------------------------------------------------

--- Re-run the active tab's command against its recorded connection and
--- replace the tab with the fresh result. Works for browser value-viewer
--- tabs (meta.connection + meta.db) and exec tabs that carry a connection.
function M.refresh()
  local tab = state.tabs[state.active]
  if not tab or not tab.meta or not tab.meta.command or tab.meta.command == "" then
    vim.notify("Nothing to refresh on this tab", vim.log.levels.INFO,
      { title = constants.TITLE })
    return
  end
  local conn_name = tab.meta.connection
  if not conn_name or conn_name == "" then
    vim.notify("This tab has no recorded connection — re-run the command instead",
      vim.log.levels.WARN, { title = constants.TITLE })
    return
  end
  local url, err = resolve_connection_url(conn_name)
  if not url then
    vim.notify("Cannot refresh: " .. tostring(err), vim.log.levels.ERROR,
      { title = constants.TITLE })
    return
  end
  local parser = require("poste-redis.parser")
  local tokens, terr = parser.command_tokens(tab.meta.command)
  if not tokens then
    vim.notify("Cannot refresh: " .. tostring(terr), vim.log.levels.ERROR,
      { title = constants.TITLE })
    return
  end
  local session_conn = require("poste-redis.session_conn")
  local dispatched = session_conn.execute(url, tokens, {
    on_response = function(ev)
      local out = format.format_result(ev)
      out.meta = tab.meta
      if out.kind == "table" then
        out.page = tab.page or 1
        out.page_size = tab.page_size or state.PAGE_SIZE
        out.cursor = tab.cursor or { row = 1, col = 1 }
        out.layout = nil
        out.pmeta = nil
        out.search_text = tab.search_text
        out.search_matches = {}
        out.search_idx = 0
      end
      state.tabs[state.active] = out
      state.last_value = out.meta and out.meta.value
      view.render_active()
      fetch_ttl()
    end,
    on_error = function(msg)
      vim.notify("Refresh failed: " .. tostring(msg), vim.log.levels.ERROR,
        { title = constants.TITLE })
    end,
  }, nil, { db = tab.meta.db })
  if dispatched ~= "dispatched" then
    vim.notify("Refresh failed: session not available (" .. tostring(dispatched) .. ")",
      vim.log.levels.ERROR, { title = constants.TITLE })
  end
end

------------------------------------------------------------------------
-- Cell navigation
------------------------------------------------------------------------

--- Move the cell cursor by (drow, dcol), clamped to the current page. Column
--- 1 is the row-index column — display-only chrome, never edited or yanked —
--- so the cursor bottoms out at the first content column (2) and h from
--- there stays put.
function M.move_cell(drow, dcol)
  local tab = state.tabs[state.active]
  if not tab or tab.kind ~= "table" or not tab.pmeta or tab.pmeta.row_count == 0 then return end
  local row = math.max(1, math.min(tab.cursor.row + drow, tab.pmeta.row_count))
  local min_col = math.min(2, math.max(tab.pmeta.col_count, 1))
  local col = math.max(min_col, math.min(tab.cursor.col + dcol, tab.pmeta.col_count))
  if row == tab.cursor.row and col == tab.cursor.col then return end
  tab.cursor.row, tab.cursor.col = row, col
  view.highlight_cell(tab)
  view.position_cursor(tab)
  view.update_header()
  view.update_winbar()
end

function M.goto_first_row()
  local tab = state.tabs[state.active]
  if not tab or tab.kind ~= "table" or not tab.pmeta or tab.pmeta.row_count == 0 then return end
  tab.cursor.row = 1
  view.highlight_cell(tab)
  view.position_cursor(tab)
  view.update_header()
  view.update_winbar()
end

function M.goto_last_row()
  local tab = state.tabs[state.active]
  if not tab or tab.kind ~= "table" or not tab.pmeta or tab.pmeta.row_count == 0 then return end
  tab.cursor.row = tab.pmeta.row_count
  view.highlight_cell(tab)
  view.position_cursor(tab)
  view.update_header()
  view.update_winbar()
end

------------------------------------------------------------------------
-- Page / search / preview / yank — thin delegations to buffer/* modules
------------------------------------------------------------------------

function M.next_page() pager.next() end

function M.prev_page() pager.prev() end

function M.goto_first_page() pager.first() end

function M.goto_last_page() pager.last() end

function M.show_search() search.show() end

function M.next_search_match() search.next() end

function M.prev_search_match() search.prev() end

function M.preview_raw()
  local tab = state.tabs[state.active]
  preview.raw(state.last_value, tab and tab.meta)
end

function M.preview_cell()
  preview.cell(state.tabs[state.active], state.last_value)
end

function M.yank_current()
  yank.current(state.tabs[state.active])
end

function M.yank_cell()
  yank.cell(state.tabs[state.active])
end

function M.yank_column()
  yank.column(state.tabs[state.active])
end

--- `s` on a content column: cycle none → desc → asc → none and pin the sort
--- icon next to the column name in the header.
function M.sort_column()
  local tab = state.tabs[state.active]
  local handled = sort.toggle(tab)
  if not handled then return end
  view.render_active()
  view.position_cursor(tab)
end

------------------------------------------------------------------------
-- Render entry points
------------------------------------------------------------------------

--- Store + optionally render a fresh result list.
--- @param results table[]  result events (or { type="result", error=... } stubs)
--- @param opts table { src_buf, connection, render = boolean } — connection
---   (name or URL) is stamped into every tab's meta so `r` can re-run it
function M.render(results, opts)
  opts = opts or {}
  local parser = require("poste-redis.parser")
  state.tabs = {}
  state.active = 1
  state.last_value = nil
  for _, ev in ipairs(results or {}) do
    local out = format.format_result(ev)
    -- named USE groups win over the run-level fallback (URL) so the winbar
    -- shows "local db3", not a host
    out.meta.connection = ev.connection_name or opts.connection or out.meta.connection
    -- Context travels with the result: the db the command ran on (stamped by
    -- exec_run, SELECT-aware) and, for editable grid tabs, the key argument —
    -- grid_edit needs both to write where the command actually was.
    out.meta.db = ev.db or out.meta.db
    if out.kind == "table" then
      local tokens = parser.command_tokens(out.meta.command)
      if tokens and #tokens >= 2 then out.meta.key = tokens[2] end
    end
    if out.kind == "table" then
      out.page = 1
      out.page_size = state.PAGE_SIZE
      out.cursor = { row = 1, col = 2 }  -- col 1 is the index column: not focusable
      out.layout = nil
      out.pmeta = nil
      out.search_text = nil
      out.search_matches = {}
      out.search_idx = 0
    end
    state.tabs[#state.tabs + 1] = out
    if out.meta.dangerous then
      vim.notify("Dangerous command: " .. out.meta.command, vim.log.levels.WARN,
        { title = constants.TITLE })
    end
  end
  if #state.tabs == 0 then
    state.tabs = { { kind = "text", lines = { "(no results)" }, meta = {} } }
  end
  state.last_value = state.tabs[state.active].meta.value
  if opts.render ~= false then
    M.show_panel(false)
    view.render_active()
    fetch_ttl()
  end
end

--- Render a pre-formatted tab list (browser value viewer pages). Each tab is
--- a { lines, meta } or { grid, meta } pair already formatted.
--- @param tab_list table[]
--- @param opts? table { render = boolean }
function M.render_tabs(tab_list, opts)
  opts = opts or {}
  state.tabs = tab_list or {}
  state.active = 1
  for _, t in ipairs(state.tabs) do
    if t.kind == "table" then
      t.page = t.page or 1
      t.page_size = t.page_size or state.PAGE_SIZE
      t.cursor = t.cursor or { row = 1, col = 2 }
      t.layout = t.layout or nil
      t.search_text = t.search_text or nil
      t.search_matches = t.search_matches or {}
      t.search_idx = t.search_idx or 0
    end
  end
  state.last_value = state.tabs[state.active] and state.tabs[state.active].meta
    and state.tabs[state.active].meta.value
  if opts.render ~= false then
    M.show_panel(false)
    view.render_active()
    fetch_ttl()
  end
end

--- Clear all tabs and close the panel content (keeps window if open).
function M.clear()
  stop_ttl_timer()
  state.tabs = {}
  state.active = 1
  state.last_value = nil
  view.close_header()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    vim.api.nvim_set_option_value("modifiable", true, { buf = state.buf })
    vim.api.nvim_buf_set_lines(state.buf, 0, vim.api.nvim_buf_line_count(state.buf), false, {})
    vim.api.nvim_set_option_value("modifiable", false, { buf = state.buf })
  end
end

--- Render a pre-formatted snapshot (history replay) as the single tab.
--- Opens the panel if needed.
--- @param lines string[]
--- @param meta table|nil
function M.render_snapshot(lines, meta)
  meta = meta or {}
  state.tabs = { { kind = "text", lines = lines or { "" }, meta = meta } }
  state.active = 1
  state.last_value = meta.value
  M.show_panel()
  view.render_active()
  fetch_ttl()
end

------------------------------------------------------------------------
-- Window management
------------------------------------------------------------------------

--- Open (or re-focus) the panel in a full-width bottom horizontal split.
--- @param enter boolean|nil  move focus to the panel (default true)
function M.show_panel(enter)
  if state.win and vim.api.nvim_win_is_valid(state.win)
      and (not state.panel_tabpage or vim.api.nvim_win_get_tabpage(state.win) ~= state.panel_tabpage) then
    pcall(vim.api.nvim_win_close, state.win, true)
    state.win = nil
    state.panel_tabpage = nil
  end
  if M.is_open() then
    if enter ~= false then
      pcall(vim.api.nvim_set_current_win, state.win)
    end
    return
  end
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = state.buf })
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = state.buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = state.buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = state.buf })
  vim.api.nvim_buf_set_name(state.buf, "poste://redis_result")
  vim.bo[state.buf].filetype = "poste_redis_result"

  local height = math.max(
    constants.RESULT_MIN_HEIGHT,
    math.floor(vim.o.lines * constants.RESULT_HEIGHT_RATIO)
  )
  local src_win = vim.api.nvim_get_current_win()
  local src_view = vim.fn.winsaveview()
  vim.cmd("botright " .. height .. "split")
  state.win = vim.api.nvim_get_current_win()
  state.panel_tabpage = vim.api.nvim_get_current_tabpage()
  vim.api.nvim_win_set_buf(state.win, state.buf)
  -- The grid renders its own layout; the vim gutter numbers/signs would only
  -- mislead (and shift columns). poste-db does the same for its dataset.
  vim.api.nvim_set_option_value("number", false, { win = state.win })
  vim.api.nvim_set_option_value("relativenumber", false, { win = state.win })
  vim.api.nvim_set_option_value("signcolumn", "no", { win = state.win })
  vim.api.nvim_set_option_value("foldcolumn", "0", { win = state.win })
  vim.api.nvim_set_option_value("wrap", false, { win = state.win })
  if enter ~= false then
    vim.api.nvim_set_current_win(state.win)
  else
    vim.api.nvim_set_current_win(src_win)
    vim.fn.winrestview(src_view)
  end

  -- Horizontal scroll on the panel (zh/zl, mouse) keeps the floating header
  -- in sync with the body.
  if scroll_autocmd_id then
    pcall(vim.api.nvim_del_autocmd, scroll_autocmd_id)
    scroll_autocmd_id = nil
  end
  scroll_autocmd_id = vim.api.nvim_create_autocmd("WinScrolled", {
    buffer = state.buf,
    callback = function()
      local tab = state.tabs[state.active]
      if tab and tab.kind == "table" and tab.header_padded then
        view.update_header()
      end
    end,
  })

  setup_keymaps()
end

------------------------------------------------------------------------
-- Keymaps
------------------------------------------------------------------------

--- Bind the `redis_result` keymaps onto the panel buffer (see config.defaults).
function setup_keymaps()
  local km = { buffer = state.buf, noremap = true, silent = true }
  local k = config.get_keymap("redis_result", "close", "q")
  if k then vim.keymap.set("n", k, function() M.close() end, km) end
  k = config.get_keymap("redis_result", "next_tab", "<Tab>")
  if k then vim.keymap.set("n", k, function() M.next_tab() end, km) end
  k = config.get_keymap("redis_result", "prev_tab", "<S-Tab>")
  if k then vim.keymap.set("n", k, function() M.prev_tab() end, km) end

  -- Grid navigation (table tabs)
  k = config.get_keymap("redis_result", "move_left", "h")
  if k then vim.keymap.set("n", k, function() M.move_cell(0, -1) end, km) end
  k = config.get_keymap("redis_result", "move_down", "j")
  if k then vim.keymap.set("n", k, function() M.move_cell(1, 0) end, km) end
  k = config.get_keymap("redis_result", "move_up", "k")
  if k then vim.keymap.set("n", k, function() M.move_cell(-1, 0) end, km) end
  k = config.get_keymap("redis_result", "move_right", "l")
  if k then vim.keymap.set("n", k, function() M.move_cell(0, 1) end, km) end
  k = config.get_keymap("redis_result", "first_row", "gg")
  if k then vim.keymap.set("n", k, function() M.goto_first_row() end, km) end
  k = config.get_keymap("redis_result", "last_row", "G")
  if k then vim.keymap.set("n", k, function() M.goto_last_row() end, km) end
  k = config.get_keymap("redis_result", "prev_page", "H")
  if k then vim.keymap.set("n", k, function() M.prev_page() end, km) end
  k = config.get_keymap("redis_result", "next_page", "L")
  if k then vim.keymap.set("n", k, function() M.next_page() end, km) end
  k = config.get_keymap("redis_result", "goto_first_page", "<leader>hh")
  if k then vim.keymap.set("n", k, function() M.goto_first_page() end, km) end
  k = config.get_keymap("redis_result", "goto_last_page", "<leader>ll")
  if k then vim.keymap.set("n", k, function() M.goto_last_page() end, km) end
  k = config.get_keymap("redis_result", "preview_cell", "K")
  if k then vim.keymap.set("n", k, function() M.preview_cell() end, km) end
  k = config.get_keymap("redis_result", "yank_cell", "yy")
  if k then vim.keymap.set("n", k, function() M.yank_cell() end, km) end
  k = config.get_keymap("redis_result", "yank_column", "yc")
  if k then vim.keymap.set("n", k, function() M.yank_column() end, km) end
  k = config.get_keymap("redis_result", "show_search", "<leader>/")
  if k then vim.keymap.set("n", k, function() M.show_search() end, km) end
  k = config.get_keymap("redis_result", "next_search", "n")
  if k then vim.keymap.set("n", k, function() M.next_search_match() end, km) end
  k = config.get_keymap("redis_result", "prev_search", "N")
  if k then vim.keymap.set("n", k, function() M.prev_search_match() end, km) end
  k = config.get_keymap("redis_result", "refresh", "r")
  if k then vim.keymap.set("n", k, function() M.refresh() end, km) end
  k = config.get_keymap("redis_result", "sort_column", "s")
  if k then vim.keymap.set("n", k, function() M.sort_column() end, km) end

  -- Grid editing (poste-db dataset pattern): i edit cell, o add row, dd delete
  local grid_edit = require("poste-redis.browser.grid_edit")
  grid_edit.set_refresh(function() M.refresh() end)
  k = config.get_keymap("redis_result", "edit_cell", "i")
  if k then
    vim.keymap.set("n", k, function()
      grid_edit.edit_cell(state.tabs[state.active])
    end, km)
  end
  k = config.get_keymap("redis_result", "add_row", "o")
  if k then
    vim.keymap.set("n", k, function()
      grid_edit.add_row(state.tabs[state.active])
    end, km)
  end
  k = config.get_keymap("redis_result", "delete_row", "dd")
  if k then
    vim.keymap.set("n", k, function()
      grid_edit.delete_row(state.tabs[state.active])
    end, km)
  end

  -- F: full-load a truncated string value (browser value viewer)
  k = config.get_keymap("redis_result", "load_full", "F")
  if k then
    vim.keymap.set("n", k, function()
      local ok, value_mod = pcall(require, "poste-redis.browser.value")
      if ok and value_mod.load_full then value_mod.load_full() end
    end, km)
  end
end

function M.next_tab()
  if #state.tabs < 2 then return end
  state.active = state.active + 1
  if state.active > #state.tabs then state.active = 1 end
  state.last_value = state.tabs[state.active].meta.value
  view.render_active()
  fetch_ttl()
end

function M.prev_tab()
  if #state.tabs < 2 then return end
  state.active = state.active - 1
  if state.active < 1 then state.active = #state.tabs end
  state.last_value = state.tabs[state.active].meta.value
  view.render_active()
  fetch_ttl()
end

function M.close()
  stop_ttl_timer()
  if scroll_autocmd_id then
    pcall(vim.api.nvim_del_autocmd, scroll_autocmd_id)
    scroll_autocmd_id = nil
  end
  view.close_header()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  state.win = nil
  state.panel_tabpage = nil
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end
  state.buf = nil
end

--- Buffer/window handles for tests.
function M.buf()
  return state.buf
end

function M.win()
  return state.win
end

function M._tabs()
  return state.tabs
end

M._test = {
  PAGE_SIZE = state.PAGE_SIZE,
}

return M
