--- M1 result panel (EXECUTION-PLAN D2) + table grid (poste-db dataset style).
---
--- A single scratch buffer `poste://redis_result` in a bottom split, one tab
--- per executed command. Scalars (string/error/binary/...) render as a compact
--- text block; Set/List/Hash/Zset render as a `│`-separated table grid with a
--- floating fixed header, scrollable body, pagination, cell navigation,
--- search, and yank (see poste-redis.result.grid / .header). Grid features are
--- only active on table tabs — text tabs keep the old redis-cli-style block.
local config = require("poste-redis.config")
local constants = require("poste-redis.constants")
local format = require("poste-redis.format")
local grid = require("poste-redis.result.grid")
local header = require("poste-redis.result.header")

local M = {}

local buf = nil
local win = nil
local panel_tabpage = nil
local tabs = {}          -- { { kind="text", lines, meta } | { kind="table", grid, meta, page, ... } }
local active = 1         -- 1-based
local last_value = nil   -- current tab's raw value for K preview

--- Grid pagination: rows per page.
local PAGE_SIZE = 50

--- Extmark namespaces (cell highlight + search matches).
local cell_ns = vim.api.nvim_create_namespace("poste_redis_cell")
local search_ns = vim.api.nvim_create_namespace("poste_redis_search")

local scroll_autocmd_id = nil

-- Forward declarations (Lua pitfall: `local function` defined later is a new
-- local, so earlier closures would capture a nil global instead).
local render_active_grid
local update_winbar

------------------------------------------------------------------------
-- Float preview (K) — simple centered float
------------------------------------------------------------------------

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

--- Show the raw JSON of the current tab's value in a float (text tabs).
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

--- Preview the current cell (table tabs) or the raw value (text tabs).
function M.preview_cell()
  local tab = tabs[active]
  if not tab or tab.kind ~= "table" then
    M.preview_raw()
    return
  end
  local global_row = (tab.page - 1) * tab.page_size + tab.cursor.row
  local row_data = tab.grid.rows[global_row]
  local col = tab.cursor.col
  if not row_data or not row_data[col] then return end
  local raw = row_data[col]
  local text
  if type(raw) == "table" then
    text = format.preview_json(raw)
  else
    text = tostring(raw)
  end
  local lines = {}
  for line in text:gmatch("[^\n]+") do lines[#lines + 1] = line end
  preview_float(lines, (tab.grid.columns[col] or "cell") .. " · row " .. global_row)
end

------------------------------------------------------------------------
-- Yank
------------------------------------------------------------------------

--- Yank the current tab's rendered lines (text tabs) or whole grid (table).
function M.yank_current()
  local tab = tabs[active]
  if not tab then return end
  if tab.kind == "table" then
    local parts = {}
    for _, row in ipairs(tab.grid.rows) do
      local cells = {}
      for i = 2, #row do cells[#cells + 1] = tab.grid.to_copy(row[i]) end
      parts[#parts + 1] = table.concat(cells, "\t")
    end
    vim.fn.setreg('"', table.concat(parts, "\n"))
    vim.notify("Yanked result", vim.log.levels.INFO, { title = constants.TITLE })
    return
  end
  vim.fn.setreg('"', table.concat(tab.lines or {}, "\n"))
  vim.notify("Yanked result", vim.log.levels.INFO, { title = constants.TITLE })
end

--- Yank the current cell (table tabs) / whole tab (text tabs).
function M.yank_cell()
  local tab = tabs[active]
  if not tab or tab.kind ~= "table" then
    M.yank_current()
    return
  end
  local global_row = (tab.page - 1) * tab.page_size + tab.cursor.row
  local row_data = tab.grid.rows[global_row]
  local col = tab.cursor.col
  if not row_data or not row_data[col] then return end
  local text = tab.grid.to_copy(row_data[col])
  vim.fn.setreg('"', text)
  vim.fn.setreg('+', text)
  local col_name = tab.grid.columns[col] or ""
  vim.notify(string.format('Yanked %s: %s', col_name, text:sub(1, 40)),
    vim.log.levels.INFO, { title = constants.TITLE })
end

--- Yank the current column's values (table tabs), one per line.
function M.yank_column()
  local tab = tabs[active]
  if not tab or tab.kind ~= "table" then return end
  local col = tab.cursor.col
  local values = {}
  for _, row in ipairs(tab.grid.rows) do
    values[#values + 1] = row[col] and tab.grid.to_copy(row[col]) or ""
  end
  vim.fn.setreg('"', table.concat(values, "\n"))
  vim.fn.setreg('+', table.concat(values, "\n"))
  local col_name = tab.grid.columns[col] or ""
  vim.notify(string.format('Yanked %d values from "%s"', #values, col_name),
    vim.log.levels.INFO, { title = constants.TITLE })
end

------------------------------------------------------------------------
-- Panel state
------------------------------------------------------------------------

function M.is_open()
  return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
    and win ~= nil and vim.api.nvim_win_is_valid(win)
end

function M.tab_count()
  return #tabs
end

--- The active tab object.
function M.active_tab()
  return tabs[active]
end

------------------------------------------------------------------------
-- Grid helpers
------------------------------------------------------------------------

--- Footer line under a table grid (truncation note or value-viewer footer).
--- @param tab table
--- @return string|nil
local function build_footer(tab)
  local meta_footer = tab.meta and tab.meta.footer
  if meta_footer and meta_footer ~= "" then return meta_footer end
  local g = tab.grid
  if g.truncated then
    return string.format("  (%d elements total, %d shown — server output capped)", g.total, #g.rows)
  end
  return nil
end

--- Clear + re-place the current-cell extmark.
local function clear_cell_highlight()
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, cell_ns, 0, -1)
  end
end

local function highlight_cell(tab)
  clear_cell_highlight()
  if not tab or tab.kind ~= "table" or not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  local pmeta = tab.pmeta
  if not pmeta or pmeta.row_count == 0 then return end
  local cs = pmeta.col_starts[tab.cursor.row]
  local range = cs and cs[tab.cursor.col]
  if not range then return end
  local line_idx = pmeta.data_start_line + tab.cursor.row - 1
  vim.api.nvim_buf_set_extmark(buf, cell_ns, line_idx - 1, range.ext_start, {
    end_row = line_idx - 1,
    end_col = range.ext_end,
    hl_group = "PosteRedisResultCell",
    priority = 200,
  })
end

--- Place the physical cursor on the current cell, scrolling horizontally if
--- the cell is off-screen.
local function position_cursor(tab)
  local pmeta = tab.pmeta
  if not pmeta or pmeta.row_count == 0 or not win or not vim.api.nvim_win_is_valid(win) then return end
  local cs = pmeta.col_starts[tab.cursor.row]
  local range = cs and cs[tab.cursor.col]
  if not range then return end
  local line_idx = pmeta.data_start_line + tab.cursor.row - 1
  local line = vim.api.nvim_buf_get_lines(buf, line_idx - 1, line_idx, false)[1] or ""
  local disp = vim.fn.strdisplaywidth(line:sub(1, range.ext_start))
  local saved = vim.fn.winsaveview()
  local win_width = vim.api.nvim_win_get_width(win)
  if disp < saved.leftcol or disp >= saved.leftcol + win_width - 1 then
    local v = vim.fn.winsaveview()
    v.leftcol = math.max(0, disp - math.floor(win_width / 4))
    vim.fn.winrestview(v)
  end
  pcall(vim.api.nvim_win_set_cursor, win, { line_idx, range.ext_start })
end

--- (Re)draw the floating header for the active grid tab.
local function update_header()
  local tab = tabs[active]
  if tab and tab.kind == "table" and tab.header_padded and win
      and vim.api.nvim_win_is_valid(win) then
    header.update(win, tab.header_padded)
  else
    header.close()
  end
end

------------------------------------------------------------------------
-- Search
------------------------------------------------------------------------

local function compute_search(tab)
  tab.search_matches = {}
  tab.search_idx = 0
  if not tab.search_text or tab.search_text == "" then return end
  tab.search_matches = grid.compute_matches(tab.grid, tab.search_text)
end

local function apply_search_highlights(tab)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  vim.api.nvim_buf_clear_namespace(buf, search_ns, 0, -1)
  if not tab or tab.kind ~= "table" or not tab.search_text
      or #tab.search_matches == 0 or not tab.pmeta then return end
  local pmeta = tab.pmeta
  local start_row = (tab.page - 1) * tab.page_size + 1
  for i, m in ipairs(tab.search_matches) do
    local vis_row = m.row - start_row + 1
    if vis_row >= 1 and vis_row <= pmeta.row_count then
      local cs = pmeta.col_starts[vis_row]
      local range = cs and cs[m.col]
      if range then
        local line_idx = pmeta.data_start_line + vis_row - 1
        local line = vim.api.nvim_buf_get_lines(buf, line_idx - 1, line_idx, false)[1] or ""
        local s, e = grid.cell_match_range(line, range, tab.search_text:lower())
        if s then
          local hl = (i == tab.search_idx) and "PosteRedisResultSearchCurrent" or "PosteRedisResultSearchMatch"
          vim.api.nvim_buf_set_extmark(buf, search_ns, line_idx - 1, s, {
            end_row = line_idx - 1,
            end_col = e,
            hl_group = hl,
            priority = 150,
          })
        end
      end
    end
  end
end

local function jump_to_match(tab, idx)
  local m = tab.search_matches[idx]
  if not m then return end
  tab.search_idx = idx
  local target_page = math.ceil(m.row / tab.page_size)
  if target_page ~= tab.page then
    tab.page = target_page
    render_active_grid(tab)
  end
  local vis_row = m.row - (tab.page - 1) * tab.page_size
  tab.cursor.row = vis_row
  tab.cursor.col = m.col
  highlight_cell(tab)
  position_cursor(tab)
  apply_search_highlights(tab)
  update_winbar()
end

--- Interactive search over grid cell values (case-insensitive substring).
function M.show_search()
  local tab = tabs[active]
  if not tab or tab.kind ~= "table" then return end
  vim.ui.input({ prompt = "Search in results: ", default = tab.search_text or "" }, function(text)
    if text == nil then return end
    tab.search_text = text
    compute_search(tab)
    if #tab.search_matches > 0 then
      jump_to_match(tab, 1)
    else
      apply_search_highlights(tab)
      update_winbar()
      if text ~= "" then
        vim.notify("No matches for '" .. text .. "'", vim.log.levels.INFO, { title = constants.TITLE })
      end
    end
  end)
end

function M.next_search_match()
  local tab = tabs[active]
  if not tab or tab.kind ~= "table" or #tab.search_matches == 0 then return end
  jump_to_match(tab, (tab.search_idx % #tab.search_matches) + 1)
end

function M.prev_search_match()
  local tab = tabs[active]
  if not tab or tab.kind ~= "table" or #tab.search_matches == 0 then return end
  local idx = ((tab.search_idx - 2 + #tab.search_matches) % #tab.search_matches) + 1
  jump_to_match(tab, idx)
end

------------------------------------------------------------------------
-- Cell / page navigation
------------------------------------------------------------------------

--- Move the cell cursor by (drow, dcol), clamped to the current page.
function M.move_cell(drow, dcol)
  local tab = tabs[active]
  if not tab or tab.kind ~= "table" or not tab.pmeta or tab.pmeta.row_count == 0 then return end
  local row = math.max(1, math.min(tab.cursor.row + drow, tab.pmeta.row_count))
  local col = math.max(1, math.min(tab.cursor.col + dcol, tab.pmeta.col_count))
  if row == tab.cursor.row and col == tab.cursor.col then return end
  tab.cursor.row, tab.cursor.col = row, col
  highlight_cell(tab)
  position_cursor(tab)
  update_header()
  update_winbar()
end

function M.goto_first_row()
  local tab = tabs[active]
  if not tab or tab.kind ~= "table" or not tab.pmeta or tab.pmeta.row_count == 0 then return end
  tab.cursor.row = 1
  highlight_cell(tab)
  position_cursor(tab)
  update_header()
  update_winbar()
end

function M.goto_last_row()
  local tab = tabs[active]
  if not tab or tab.kind ~= "table" or not tab.pmeta or tab.pmeta.row_count == 0 then return end
  tab.cursor.row = tab.pmeta.row_count
  highlight_cell(tab)
  position_cursor(tab)
  update_header()
  update_winbar()
end

--- Re-render the active grid tab's current page + re-place the cursor.
local function refresh_page()
  local tab = tabs[active]
  if not tab or tab.kind ~= "table" then return end
  render_active_grid(tab)
  highlight_cell(tab)
  position_cursor(tab)
  update_winbar()
end

function M.next_page()
  local tab = tabs[active]
  if not tab or tab.kind ~= "table" or not tab.num_pages or tab.num_pages <= 1 then return end
  tab.page = tab.page + 1
  if tab.page > tab.num_pages then tab.page = 1 end
  refresh_page()
end

function M.prev_page()
  local tab = tabs[active]
  if not tab or tab.kind ~= "table" or not tab.num_pages or tab.num_pages <= 1 then return end
  tab.page = tab.page - 1
  if tab.page < 1 then tab.page = tab.num_pages end
  refresh_page()
end

function M.goto_first_page()
  local tab = tabs[active]
  if not tab or tab.kind ~= "table" or not tab.num_pages or tab.num_pages <= 1 then return end
  tab.page = 1
  refresh_page()
end

function M.goto_last_page()
  local tab = tabs[active]
  if not tab or tab.kind ~= "table" or not tab.num_pages or tab.num_pages <= 1 then return end
  tab.page = tab.num_pages
  refresh_page()
end

------------------------------------------------------------------------
-- Winbar
------------------------------------------------------------------------

update_winbar = function()
  if not win or not vim.api.nvim_win_is_valid(win) then return end
  local tab = tabs[active]
  local meta = tab and tab.meta
  local bar_parts = {}
  if #tabs > 1 then
    bar_parts[#bar_parts + 1] = ("%d/%d"):format(active, #tabs)
  end
  local status = meta and format.status_summary(meta) or ""
  if status ~= "" then
    bar_parts[#bar_parts + 1] = status
  end
  if tab and tab.kind == "table" and tab.grid then
    local rows = #tab.grid.rows
    local total = tab.grid.total or rows
    bar_parts[#bar_parts + 1] = string.format("rows %d/%d", rows, total)
    if tab.num_pages and tab.num_pages > 1 then
      bar_parts[#bar_parts + 1] = string.format("P %d/%d", tab.page, tab.num_pages)
    end
    if tab.search_text and tab.search_text ~= "" then
      bar_parts[#bar_parts + 1] = string.format("/%s %d/%d", tab.search_text, tab.search_idx, #tab.search_matches)
    end
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

------------------------------------------------------------------------
-- Render
------------------------------------------------------------------------

--- Render the active grid tab's current page into the buffer + header float.
render_active_grid = function(tab)
  if not tab.layout then
    tab.layout = grid.build_layout(tab.grid)
  end
  local total = #tab.grid.rows
  tab.num_pages = math.max(1, math.ceil(total / tab.page_size))
  tab.page = math.max(1, math.min(tab.page or 1, tab.num_pages))
  if tab.cursor.row > tab.page_size then tab.cursor.row = 1 end

  local footer = build_footer(tab)
  local lines, pmeta = grid.render_page(tab.grid, tab.layout, tab.page, tab.page_size, footer)

  -- The in-buffer header is replaced by a blank line at line 1: the floating
  -- header overlays that blank, leaving every data row visible below it.
  -- Offsets are unchanged (header and blank both occupy line 1), so pmeta's
  -- data_start_line = 2 stays correct.
  local body = { "" }
  for i = 2, #lines do body[#body + 1] = lines[i] end
  tab.padded = body
  tab.pmeta = pmeta
  tab.header_padded = lines[1]

  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  -- explicit end index: nvim 0.12's set_lines(-1) path can starve job stdout
  -- while results stream in (see browser/tree.lua render_tree note)
  vim.api.nvim_buf_set_lines(buf, 0, vim.api.nvim_buf_line_count(buf), false, body)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  update_header()
  highlight_cell(tab)
  apply_search_highlights(tab)
end

--- Render the active tab into the buffer + winbar + header float.
local function render_active()
  if not M.is_open() then return end
  local tab = tabs[active]
  if tab and tab.kind == "table" then
    render_active_grid(tab)
  else
    header.close()
    local lines = tab and tab.lines or { "" }
    vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
    vim.api.nvim_buf_set_lines(buf, 0, vim.api.nvim_buf_line_count(buf), false, lines)
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  end
  update_winbar()
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
    if out.kind == "table" then
      out.page = 1
      out.page_size = PAGE_SIZE
      out.cursor = { row = 1, col = 1 }
      out.layout = nil
      out.pmeta = nil
      out.search_text = nil
      out.search_matches = {}
      out.search_idx = 0
    end
    tabs[#tabs + 1] = out
    if out.meta.dangerous then
      vim.notify("Dangerous command: " .. out.meta.command, vim.log.levels.WARN,
        { title = constants.TITLE })
    end
  end
  if #tabs == 0 then
    tabs = { { kind = "text", lines = { "(no results)" }, meta = {} } }
  end
  last_value = tabs[active].meta.value
  if opts.render ~= false then
    M.show_panel(false)
    render_active()
  end
end

--- Render a pre-formatted tab list (browser value viewer pages). Each tab is
--- a { lines, meta } or { grid, meta } pair already formatted.
--- @param tab_list table[]
--- @param opts? table { render = boolean }
function M.render_tabs(tab_list, opts)
  opts = opts or {}
  tabs = tab_list or {}
  active = 1
  for _, t in ipairs(tabs) do
    if t.kind == "table" then
      t.page = t.page or 1
      t.page_size = t.page_size or PAGE_SIZE
      t.cursor = t.cursor or { row = 1, col = 1 }
      t.layout = t.layout or nil
      t.search_text = t.search_text or nil
      t.search_matches = t.search_matches or {}
      t.search_idx = t.search_idx or 0
    end
  end
  last_value = tabs[active] and tabs[active].meta and tabs[active].meta.value
  if opts.render ~= false then
    M.show_panel(false)
    render_active()
  end
end

--- Clear all tabs and close the panel content (keeps window if open).
function M.clear()
  tabs = {}
  active = 1
  last_value = nil
  header.close()
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
    vim.api.nvim_buf_set_lines(buf, 0, vim.api.nvim_buf_line_count(buf), false, {})
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  end
end

--- Render a pre-formatted snapshot (history replay) as the single tab.
--- Opens the panel if needed.
--- @param lines string[]
--- @param meta table|nil
function M.render_snapshot(lines, meta)
  meta = meta or {}
  tabs = { { kind = "text", lines = lines or { "" }, meta = meta } }
  active = 1
  last_value = meta.value
  M.show_panel()
  render_active()
end

------------------------------------------------------------------------
-- Window management
------------------------------------------------------------------------

--- Open (or re-focus) the panel in a full-width bottom horizontal split.
--- @param enter boolean|nil  move focus to the panel (default true)
function M.show_panel(enter)
  if win and vim.api.nvim_win_is_valid(win)
      and (not panel_tabpage or vim.api.nvim_win_get_tabpage(win) ~= panel_tabpage) then
    pcall(vim.api.nvim_win_close, win, true)
    win = nil
    panel_tabpage = nil
  end
  if M.is_open() then
    if enter ~= false then
      pcall(vim.api.nvim_set_current_win, win)
    end
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
  local src_win = vim.api.nvim_get_current_win()
  local src_view = vim.fn.winsaveview()
  vim.cmd("botright " .. height .. "split")
  win = vim.api.nvim_get_current_win()
  panel_tabpage = vim.api.nvim_get_current_tabpage()
  vim.api.nvim_win_set_buf(win, buf)
  -- The grid renders its own layout; the vim gutter numbers/signs would only
  -- mislead (and shift columns). poste-db does the same for its dataset.
  vim.api.nvim_set_option_value("number", false, { win = win })
  vim.api.nvim_set_option_value("relativenumber", false, { win = win })
  vim.api.nvim_set_option_value("signcolumn", "no", { win = win })
  vim.api.nvim_set_option_value("foldcolumn", "0", { win = win })
  vim.api.nvim_set_option_value("wrap", false, { win = win })
  if enter ~= false then
    vim.api.nvim_set_current_win(win)
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
    buffer = buf,
    callback = function()
      local tab = tabs[active]
      if tab and tab.kind == "table" and tab.header_padded then
        update_header()
      end
    end,
  })

  local km = { buffer = buf, noremap = true, silent = true }
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
  if scroll_autocmd_id then
    pcall(vim.api.nvim_del_autocmd, scroll_autocmd_id)
    scroll_autocmd_id = nil
  end
  header.close()
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  win = nil
  panel_tabpage = nil
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

M._test = {
  PAGE_SIZE = PAGE_SIZE,
}

return M
