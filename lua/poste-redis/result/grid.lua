--- poste-redis.result.grid — pure table-grid rendering for the result panel.
--- Turns a grid model (columns + raw rows, built by poste-redis.format) into
--- borderless `│`-separated buffer lines with per-cell byte maps. No vim
--- window/buffer ops, no poste deps — everything here is headless-testable.
--- The renderer is deliberately generic so the widget can later be lifted
--- into poste.nvim and shared with other satellites (poste-db style).
local util = require("poste-redis.util")

local M = {}

--- Left padding before the first `│` (mirrors poste-db's dataset).
local LEFT_PADDING = 2
local LEFT_PAD_SPACES = string.rep(" ", LEFT_PADDING)
local SEP = "│"

--- Default cap for a content column display width.
M.DEFAULT_MAX_COL_WIDTH = 80

--- Display string for a grid cell (falls back to grid.to_display).
--- @param grid table
--- @param v any
--- @return string
local function disp(grid, v)
  if grid.to_display then
    local ok, s = pcall(grid.to_display, v)
    if ok then return s == nil and "" or s end
  end
  return v == nil and "" or tostring(v)
end

local function right_set(layout, i)
  for _, r in ipairs(layout.right) do
    if r == i then return true end
  end
  return false
end

------------------------------------------------------------------------
-- Layout
------------------------------------------------------------------------

--- Compute column display widths + right-aligned columns for a grid.
--- @param grid table  { columns, rows, total, truncated, right_align, to_display }
--- @param max_col_width number|nil  cap for content columns (`#` stays narrow)
--- @return table layout { columns, widths, right, col_count, total, truncated }
function M.build_layout(grid, max_col_width)
  max_col_width = max_col_width or M.DEFAULT_MAX_COL_WIDTH
  local columns = grid.columns
  local widths = {}
  for i, h in ipairs(columns) do
    widths[i] = util.display_width(h)
  end
  for _, row in ipairs(grid.rows) do
    for i, v in ipairs(row) do
      if i <= #widths then
        widths[i] = math.max(widths[i], util.display_width(disp(grid, v)))
      end
    end
  end
  -- the `#` column fits the largest row index (from total), kept narrow
  local total = grid.total or #grid.rows
  widths[1] = math.max(widths[1], #tostring(total))
  widths[1] = math.min(widths[1], 8)
  for i = 2, #widths do
    widths[i] = math.min(widths[i], max_col_width)
  end
  local right = { 1 }
  for _, c in ipairs(grid.right_align or {}) do
    if c >= 2 and c <= #widths then right[#right + 1] = c end
  end
  return {
    columns = columns,
    widths = widths,
    right = right,
    col_count = #columns,
    total = total,
    truncated = grid.truncated,
  }
end

------------------------------------------------------------------------
-- Lines
------------------------------------------------------------------------

--- Build the header line: `  │ # │ value     │`.
--- @param layout table
--- @return string
function M.header_line(layout)
  local widths = layout.widths
  local buf = { LEFT_PAD_SPACES, SEP }
  for i, h in ipairs(layout.columns) do
    buf[#buf + 1] = " " .. util.pad_right(h, widths[i]) .. " " .. SEP
  end
  return table.concat(buf)
end

--- Build one data row: `  │ 1 │ job-1     │` with per-column byte maps.
--- @param grid table
--- @param layout table
--- @param row table[]  raw cell values (row[1] = row index)
--- @return string line, table starts  { [col] = { ext_start, ext_end } } 0-based byte cols
function M.row_line(grid, layout, row)
  local widths = layout.widths
  local buf = { LEFT_PAD_SPACES, SEP }
  local starts = {}
  local col = #buf[1] + #SEP  -- 0-based byte col right after the leading `│`
  local function emit(s)
    buf[#buf + 1] = s
    col = col + #s
  end
  for i, v in ipairs(row) do
    if i <= #widths then
      local s = disp(grid, v)
      local w = widths[i]
      if util.display_width(s) > w then s = util.truncate_display(s, w) end
      local pad = math.max(0, w - util.display_width(s))
      emit(" ")
      if right_set(layout, i) then
        emit(string.rep(" ", pad))
        starts[i] = { ext_start = col, ext_end = col + #s }
        emit(s)
      else
        starts[i] = { ext_start = col, ext_end = col + #s }
        emit(s)
        emit(string.rep(" ", pad))
      end
      emit(" ")
      emit(SEP)
    end
  end
  return table.concat(buf), starts
end

------------------------------------------------------------------------
-- Pagination
------------------------------------------------------------------------

--- Render one page of a grid. The header is line 1; data starts at line 2.
--- @param grid table
--- @param layout table
--- @param page number  1-based page
--- @param page_size number  rows per page
--- @param footer string|nil  trailing line appended after the data rows
--- @return string[] lines
--- @return table meta  { header_line, data_start_line, data_end_line, row_count,
---   col_count, widths, right, col_starts, total, truncated, page, num_pages, page_size }
function M.render_page(grid, layout, page, page_size, footer)
  local rows = grid.rows
  local total = #rows
  local num_pages = math.max(1, math.ceil(total / page_size))
  page = math.max(1, math.min(page or 1, num_pages))

  local lines = { M.header_line(layout) }
  local col_starts = {}
  if total == 0 then
    lines[#lines + 1] = LEFT_PAD_SPACES .. "(empty)"
    if footer and footer ~= "" then lines[#lines + 1] = footer end
    return lines, {
      header_line = 1,
      data_start_line = 2,
      data_end_line = 2,
      row_count = 0,
      col_count = layout.col_count,
      widths = layout.widths,
      right = layout.right,
      col_starts = {},
      total = grid.total,
      truncated = grid.truncated,
      page = page,
      num_pages = num_pages,
      page_size = page_size,
    }
  end

  local start_idx = (page - 1) * page_size + 1
  local end_idx = math.min(start_idx + page_size - 1, total)
  local data_start = #lines + 1
  for idx = start_idx, end_idx do
    local line, starts = M.row_line(grid, layout, rows[idx])
    lines[#lines + 1] = line
    col_starts[#col_starts + 1] = starts
  end
  if footer and footer ~= "" then lines[#lines + 1] = footer end

  return lines, {
    header_line = 1,
    data_start_line = data_start,
    data_end_line = data_start + (end_idx - start_idx) - 1,
    row_count = end_idx - start_idx + 1,
    col_count = layout.col_count,
    widths = layout.widths,
    right = layout.right,
    col_starts = col_starts,
    total = grid.total,
    truncated = grid.truncated,
    page = page,
    num_pages = num_pages,
    page_size = page_size,
  }
end

------------------------------------------------------------------------
-- Search
------------------------------------------------------------------------

--- Find every cell (excluding the `#` index column) whose display text
--- contains `text` (case-insensitive).
--- @param grid table
--- @param text string
--- @return table[] matches  { row = number (1-based into grid.rows), col = number }
function M.compute_matches(grid, text)
  local q = text:lower()
  local matches = {}
  for ri, row in ipairs(grid.rows) do
    for ci = 2, #row do
      local s = disp(grid, row[ci]):lower()
      if s:find(q, 1, true) then
        matches[#matches + 1] = { row = ri, col = ci }
      end
    end
  end
  return matches
end

--- Locate the byte range of the first occurrence of `needle_lower` inside a
--- cell's content (0-based byte columns, absolute within the buffer line).
--- @param line string  full buffer line
--- @param range table  { ext_start, ext_end } from col_starts
--- @param needle_lower string  lowercased search text
--- @return number|nil start_byte, number|nil end_byte (exclusive)
function M.cell_match_range(line, range, needle_lower)
  if not range then return nil, nil end
  local content = line:sub(range.ext_start + 1, range.ext_end)
  local s, e = content:lower():find(needle_lower, 1, true)
  if not s then return nil, nil end
  return range.ext_start + s - 1, range.ext_start + e
end

M._test = {
  disp = disp,
  right_set = right_set,
  LEFT_PADDING = LEFT_PADDING,
  LEFT_PAD_SPACES = LEFT_PAD_SPACES,
}

return M
