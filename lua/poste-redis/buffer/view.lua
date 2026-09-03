--- Result-panel drawing layer: everything that writes into (or floats over)
--- the panel buffer — grid page renderer, cell/value/search extmarks,
--- floating header, winbar. Reads panel state from `buffer/state.lua`;
--- `buffer/search` and `buffer/pager` call into these after mutating a tab.
local state = require("poste-redis.buffer.state")
local format = require("poste-redis.format")
local grid = require("poste-redis.result.grid")
local header = require("poste-redis.result.header")

local M = {}

--- Extmark namespaces (cell highlight + value colors + search matches).
local cell_ns = vim.api.nvim_create_namespace("poste_redis_cell")
local value_ns = vim.api.nvim_create_namespace("poste_redis_value")
local search_ns = vim.api.nvim_create_namespace("poste_redis_search")

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
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    vim.api.nvim_buf_clear_namespace(state.buf, cell_ns, 0, -1)
  end
end

function M.highlight_cell(tab)
  clear_cell_highlight()
  if not tab or tab.kind ~= "table" or not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then return end
  local pmeta = tab.pmeta
  if not pmeta or pmeta.row_count == 0 then return end
  local cs = pmeta.col_starts[tab.cursor.row]
  local range = cs and cs[tab.cursor.col]
  if not range then return end
  local line_idx = pmeta.data_start_line + tab.cursor.row - 1
  vim.api.nvim_buf_set_extmark(state.buf, cell_ns, line_idx - 1, range.ext_start, {
    end_row = line_idx - 1,
    end_col = range.ext_end,
    hl_group = "PosteRedisResultCell",
    priority = 200,
  })
end

--- Place the physical cursor on the current cell, scrolling horizontally if
--- the cell is off-screen.
function M.position_cursor(tab)
  local pmeta = tab.pmeta
  if not pmeta or pmeta.row_count == 0 or not state.win or not vim.api.nvim_win_is_valid(state.win) then return end
  local cs = pmeta.col_starts[tab.cursor.row]
  local range = cs and cs[tab.cursor.col]
  if not range then return end
  local line_idx = pmeta.data_start_line + tab.cursor.row - 1
  local line = vim.api.nvim_buf_get_lines(state.buf, line_idx - 1, line_idx, false)[1] or ""
  local disp = vim.fn.strdisplaywidth(line:sub(1, range.ext_start))
  local saved = vim.fn.winsaveview()
  local win_width = vim.api.nvim_win_get_width(state.win)
  if disp < saved.leftcol or disp >= saved.leftcol + win_width - 1 then
    local v = vim.fn.winsaveview()
    v.leftcol = math.max(0, disp - math.floor(win_width / 4))
    vim.fn.winrestview(v)
  end
  pcall(vim.api.nvim_win_set_cursor, state.win, { line_idx, range.ext_start })
end

--- (Re)draw the floating header for the active grid tab.
function M.update_header()
  local tab = state.tabs[state.active]
  if tab and tab.kind == "table" and tab.header_padded and state.win
      and vim.api.nvim_win_is_valid(state.win) then
    header.update(state.win, tab.header_padded, nil, tab.grid and tab.grid.type_hl or nil)
  else
    header.close()
  end
end

--- Close the floating grid header (text tabs / panel teardown).
function M.close_header()
  header.close()
end

function M.apply_search_highlights(tab)
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then return end
  vim.api.nvim_buf_clear_namespace(state.buf, search_ns, 0, -1)
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
        local line = vim.api.nvim_buf_get_lines(state.buf, line_idx - 1, line_idx, false)[1] or ""
        local s, e = grid.cell_match_range(line, range, tab.search_text:lower())
        if s then
          local hl = (i == tab.search_idx) and "PosteRedisResultSearchCurrent" or "PosteRedisResultSearchMatch"
          vim.api.nvim_buf_set_extmark(state.buf, search_ns, line_idx - 1, s, {
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

--- Is a raw grid cell value numeric (Number highlight) vs everything else
--- (String highlight)? Redis returns scalars as strings, so numeric-looking
--- strings ("30", "99.5") count as numbers too.
local function is_number_value(v)
  if type(v) == "number" then return true end
  if type(v) ~= "string" or v == "" then return false end
  return v:match("^%-?%d+%.?%d*$") ~= nil
end

--- Color the grid body: the index/type column gray (LineNr), numeric cells
--- Number, everything else String. Applied as extmarks so the cursor-cell
--- highlight and search matches layer above.
local function apply_value_colors(tab)
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then return end
  vim.api.nvim_buf_clear_namespace(state.buf, value_ns, 0, -1)
  if not tab or tab.kind ~= "table" or not tab.pmeta then return end
  local pmeta = tab.pmeta
  local start_row = (tab.page - 1) * tab.page_size + 1
  for vis_row = 1, pmeta.row_count do
    local cs = pmeta.col_starts[vis_row]
    if not cs then break end
    local global_row = start_row + vis_row - 1
    local raw_row = tab.grid.rows[global_row]
    local line_idx = pmeta.data_start_line + vis_row - 1
    for col = 1, pmeta.col_count do
      local range = cs[col]
      if not range then break end
      local hl
      if col == 1 then
        hl = "PosteRedisResultRowNum"
      else
        local raw = raw_row and raw_row[col]
        hl = is_number_value(raw) and "PosteRedisResultNumber" or "PosteRedisResultString"
      end
      vim.api.nvim_buf_set_extmark(state.buf, value_ns, line_idx - 1, range.ext_start, {
        end_row = line_idx - 1,
        end_col = range.ext_end,
        hl_group = hl,
        priority = 50,
      })
    end
  end
end

--- Render the active grid tab's current page into the buffer + header float.
function M.render_grid(tab)
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

  vim.api.nvim_set_option_value("modifiable", true, { buf = state.buf })
  -- explicit end index: nvim 0.12's set_lines(-1) path can starve job stdout
  -- while results stream in (see browser/tree.lua render_tree note)
  vim.api.nvim_buf_set_lines(state.buf, 0, vim.api.nvim_buf_line_count(state.buf), false, body)
  vim.api.nvim_set_option_value("modifiable", false, { buf = state.buf })

  M.update_header()
  apply_value_colors(tab)
  M.highlight_cell(tab)
  M.apply_search_highlights(tab)
end

--- Render the active tab into the buffer + winbar + header float.
function M.render_active()
  if not state.is_open() then return end
  local tab = state.tabs[state.active]
  if tab and tab.kind == "table" then
    M.render_grid(tab)
  else
    header.close()
    local lines = tab and tab.lines or { "" }
    vim.api.nvim_set_option_value("modifiable", true, { buf = state.buf })
    vim.api.nvim_buf_set_lines(state.buf, 0, vim.api.nvim_buf_line_count(state.buf), false, lines)
    vim.api.nvim_set_option_value("modifiable", false, { buf = state.buf })
  end
  M.update_winbar()
end

--- Escape literal % so the winbar's %-encoding passes user/command text
--- through untouched.
local function esc(s)
  return (s:gsub("%%", "%%%%"))
end

--- Winbar text for the command: the keyword (1st token) in
--- PosteRedisResultWinbarCmd (linked to Function), the key argument (2nd
--- token) in the green PosteRedisResultWinbarKey group (`%#Group#…%*`
--- encoding). Deliberately NOT parser.command_tokens: this is display, so
--- the typed form (case, quoting) is kept as-is.
local function format_command(cmd)
  local name, key, rest = cmd:match("^%s*(%S+)%s+(%S+)%s*(.-)%s*$")
  if not name then return "%#PosteRedisResultWinbarCmd#" .. esc(cmd) .. "%*" end
  local out = "%#PosteRedisResultWinbarCmd#" .. esc(name) .. "%*"
    .. " %#PosteRedisResultWinbarKey#" .. esc(key) .. "%*"
  if rest ~= "" then out = out .. " " .. esc(rest) end
  return out
end

function M.update_winbar()
  if not state.win or not vim.api.nvim_win_is_valid(state.win) then return end
  local tab = state.tabs[state.active]
  local meta = tab and tab.meta
  local bar_parts = {}
  if #state.tabs > 1 then
    bar_parts[#bar_parts + 1] = ("%d/%d"):format(state.active, #state.tabs)
  end
  local status = meta and format.status_summary(meta) or ""
  if status ~= "" then
    bar_parts[#bar_parts + 1] = esc(status)
  end
  if tab and tab.kind == "table" and tab.grid then
    local rows = #tab.grid.rows
    local total = tab.grid.total or rows
    bar_parts[#bar_parts + 1] = string.format("rows %d/%d", rows, total)
    if tab.num_pages and tab.num_pages > 1 then
      bar_parts[#bar_parts + 1] = string.format("P %d/%d", tab.page, tab.num_pages)
    end
    if tab.search_text and tab.search_text ~= "" then
      bar_parts[#bar_parts + 1] = string.format("/%s %d/%d",
        esc(tab.search_text), tab.search_idx, #tab.search_matches)
    end
  end
  -- Key TTL (probed by buffer.lua after each tab renders; the countdown tick
  -- repaints this): plain label, seconds in the builtin Number group.
  if type(tab and tab.ttl) == "number" then
    bar_parts[#bar_parts + 1] = "ttl %#Number#" .. tab.ttl .. "%*"
  end
  -- Where this result came from. The .redis path and the browser keep
  -- separate contexts and both land in this panel, so every tab shows its
  -- own: connection name (or credential-free host for raw URLs) + db.
  local conn = meta and meta.connection
  if conn and conn ~= "" then
    local label = conn
    if conn:sub(1, 8) == "redis://" or conn:sub(1, 9) == "rediss://" then
      -- strip userinfo before deriving the host: credentials never render
      local redacted = conn:gsub("//([^/@]+)@", "//***@")
      label = redacted:match("@([^/]+)") or redacted:match("^%a+://([^/]+)") or redacted
    end
    if type(meta.db) == "number" then
      label = label .. " db" .. meta.db
    end
    bar_parts[#bar_parts + 1] = esc(label)
  end
  local cmd = meta and meta.command or ""
  if cmd ~= "" then
    bar_parts[#bar_parts + 1] = format_command(cmd)
  end
  local bar = table.concat(bar_parts, "  ·  ")
  vim.api.nvim_set_option_value("winbar", bar, { win = state.win })
  pcall(vim.api.nvim_set_option_value, "winhl", "Normal:PosteRedisResultMeta", { win = state.win })
end

M._test = {
  format_command = format_command,
}

return M
