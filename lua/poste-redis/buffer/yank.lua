--- Yank actions for the result panel: the whole tab (rendered lines or full
--- grid), the current cell, or the current column. Callers pass the active
--- tab; `cell` falls back to `current` on text tabs.
local constants = require("poste-redis.constants")

local M = {}

--- Yank the tab's rendered lines (text tabs) or whole grid (table).
function M.current(tab)
  if not tab then return end
  local text
  if tab.kind == "table" then
    local parts = {}
    for _, row in ipairs(tab.grid.rows) do
      local cells = {}
      for i = 2, #row do cells[#cells + 1] = tab.grid.to_copy(row[i]) end
      parts[#parts + 1] = table.concat(cells, "\t")
    end
    text = table.concat(parts, "\n")
  else
    text = table.concat(tab.lines or {}, "\n")
  end
  -- `+` too, matching cell/column: without it the yank never reaches the
  -- system clipboard unless the user mapped unnamedplus themselves.
  vim.fn.setreg('"', text)
  vim.fn.setreg('+', text)
  vim.notify("Yanked result", vim.log.levels.INFO, { title = constants.TITLE })
end

--- Yank the current cell (table tabs) / whole tab (text tabs).
function M.cell(tab)
  if not tab or tab.kind ~= "table" then
    M.current(tab)
    return
  end
  local page_size = tab.page_size or 1
  local global_row = (tab.page - 1) * page_size + (tab.cursor.row or 1)
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
function M.column(tab)
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

return M
