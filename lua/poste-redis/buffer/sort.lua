--- Result-panel column sorting (dataset): `s` on a content column toggles
---   none → descending → ascending → none
--- and pins an asc/desc icon right of the column name in the grid header.
--- The index column (1) is display-only chrome and never sorts.
---
--- Sorting covers the WHOLE grid (rows carry their index cell with them), so
--- pagination follows naturally. The focused record is tracked across the
--- re-order: the cursor stays on the same row's data, page included.

local M = {}

M.DESC_ICON = "▼"
M.ASC_ICON = "▲"

--- Icon right of a sorted column's name (nil = no sort).
--- @param dir string|nil "desc" | "asc"
--- @return string|nil
function M.icon(dir)
  if dir == "desc" then return M.DESC_ICON end
  if dir == "asc" then return M.ASC_ICON end
  return nil
end

--- Cell comparison: numeric when BOTH sides look numeric (redis replies are
--- strings — scores like "99" must order numerically), else by string.
--- @return number -1 | 0 | 1
function M.compare(a, b)
  local na = type(a) == "number" and a or (type(a) == "string" and tonumber(a) or nil)
  local nb = type(b) == "number" and b or (type(b) == "string" and tonumber(b) or nil)
  if na and nb then
    if na < nb then return -1 elseif na > nb then return 1 else return 0 end
  end
  local sa, sb = tostring(a or ""), tostring(b or "")
  if sa < sb then return -1 elseif sa > sb then return 1 else return 0 end
end

--- Stable sort of grid rows by column: ties keep their original relative
--- order (table.sort is not stable — the original index is the tiebreak).
--- Returns a NEW array; the row tables themselves are shared, not copied.
--- @param rows table[]
--- @param col number 1-based grid column
--- @param dir string "desc" | "asc"
--- @return table[]
function M.apply(rows, col, dir)
  local mult = (dir == "asc") and 1 or -1
  local order = {}
  for i = 1, #rows do order[i] = i end
  table.sort(order, function(x, y)
    local c = M.compare(rows[x][col], rows[y][col])
    if c ~= 0 then return c * mult < 0 end
    return x < y
  end)
  local out = {}
  for i, r in ipairs(order) do out[i] = rows[r] end
  return out
end

--- Cycle the sort state of a tab for the column under the cursor:
---   none → desc → asc → none (a different column starts fresh at desc).
--- Re-orders tab.grid.rows (the untouched original is kept once and
--- restored on the way back to none) and invalidates the tab layout so the
--- header re-renders with the sort icon. The cursor follows the focused
--- record across the re-order, page included.
--- @param tab table  active panel tab (table kind)
--- @return boolean handled  false when there is nothing to sort
--- @return table|nil sort_state  the new state { col, dir } (nil = no sort)
function M.toggle(tab)
  if not tab or tab.kind ~= "table" or not tab.grid or #(tab.grid.rows or {}) == 0 then
    return false, nil
  end
  local col = tab.cursor and tab.cursor.col or 1
  if col < 2 then return false, nil end  -- the index column is not sortable

  local dir
  if tab.sort and tab.sort.col == col then
    dir = (tab.sort.dir == "desc") and "asc" or nil
  else
    dir = "desc"
  end

  -- keep the focused record under the cursor across the re-order
  local page_size = tab.page_size or 1
  local global_row = (tab.page - 1) * page_size + (tab.cursor.row or 1)
  local focused = tab.grid.rows[global_row]

  if not tab.rows_base then tab.rows_base = tab.grid.rows end
  if dir then
    tab.grid.rows = M.apply(tab.rows_base, col, dir)
  else
    tab.grid.rows = tab.rows_base  -- none: back to the server's order
  end

  if focused then
    for i, r in ipairs(tab.grid.rows) do
      if r[1] == focused[1] then
        tab.page = math.floor((i - 1) / page_size) + 1
        tab.cursor.row = i - (tab.page - 1) * page_size
        break
      end
    end
  end

  tab.layout = nil  -- widths rebuild: the sorted header carries the icon
  tab.sort = dir and { col = col, dir = dir } or nil
  return true, tab.sort
end

--- Byte range (0-based, end-exclusive) of the sort icon inside the RENDERED
--- header line. Positions come from walking the `│` separators — widths
--- cannot be accumulated arithmetically because multibyte glyphs (the nerd
--- icons) make byte lengths differ from display widths. The sorted column's
--- cell renders as `<space> <name> <icon> <pad> <space>`: the pad after the
--- icon is whatever the column width has left over, so the icon is located
--- by plain find inside the cell region, not by counting back from the end
--- (counting back highlighted padding on any column wider than its header).
--- @param header_line string  the rendered header line (tab.header_padded)
--- @param sort table|nil { col, dir }
--- @return table|nil { start, end_ }
function M.icon_range(header_line, sort)
  if not sort or not sort.dir then return nil end
  local icon = M.icon(sort.dir)
  if not icon then return nil end
  -- sep[1] closes the left padding; the sorted column's cell sits between
  -- sep[col] and sep[col + 1]
  local sep_col, region_end = nil, nil  -- 1-based byte of sep[col], 0-based of sep[col + 1]
  local from = 1
  for i = 1, sort.col + 1 do
    local s = header_line:find("│", from, true)
    if not s then return nil end
    if i == sort.col then sep_col = s end
    region_end = s - 1
    from = s + 3  -- "│" is 3 bytes
  end
  if not sep_col or not region_end then return nil end
  local s = header_line:find(icon, sep_col, true)
  if not s or s - 1 >= region_end then return nil end
  return { s - 1, s - 1 + #icon }
end

--- Decorated header columns: the sorted column's name gains ` <icon>` so the
--- width math reserves room for it.
--- @param columns string[]
--- @param sort table|nil
--- @return string[]
function M.decorated_columns(columns, sort)
  local out = {}
  for i, h in ipairs(columns) do
    local icon = (sort and sort.col == i) and M.icon(sort.dir) or nil
    out[i] = icon and (h .. " " .. icon) or h
  end
  return out
end

M._test = {
  compare = M.compare,
}

return M
