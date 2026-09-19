--- Result-grid export (P2 "export"): write the active table tab's WHOLE grid
--- (all pages, server order) to a file as CSV / TSV / JSON. The index column
--- is display-only chrome and never exported — the same rule `y` follows.
---
--- Pure transforms (to_csv/to_tsv/to_json) take { columns, rows, to_copy } so
--- they are headless-testable; M.export() only adds the pickers + file write.

local constants = require("poste-redis.constants")

local M = {}

--- CSV field quoting per RFC 4180: quote when the field contains a comma,
--- quote, CR or LF; double embedded quotes.
---@param field string
---@return string
function M.csv_field(field)
  if field:find('[,"\r\n]') then
    return '"' .. field:gsub('"', '""') .. '"'
  end
  return field
end

--- Content lines for `csv`: header row + one row per grid row (values only,
--- the index column skipped). Returns a list of lines so the writer stays
--- format-agnostic in its join.
---@param grid table { columns, rows, to_copy }
---@return string[]
function M.to_csv(grid)
  local copy = grid.to_copy
  local lines = {}
  local header = {}
  for i = 2, #grid.columns do header[#header + 1] = M.csv_field(grid.columns[i]) end
  lines[#lines + 1] = table.concat(header, ",")
  for _, row in ipairs(grid.rows or {}) do
    local cells = {}
    for i = 2, #row do cells[#cells + 1] = M.csv_field(copy(row[i])) end
    lines[#lines + 1] = table.concat(cells, ",")
  end
  return lines
end

--- Content lines for `tsv`: same shape as CSV, tab-separated, no quoting
--- (embedded newlines inside a field would break the row shape — CSV is the
--- format to pick for dirty data).
---@param grid table
---@return string[]
function M.to_tsv(grid)
  local copy = grid.to_copy
  local lines = {}
  local header = {}
  for i = 2, #grid.columns do header[#header + 1] = grid.columns[i] end
  lines[#lines + 1] = table.concat(header, "\t")
  for _, row in ipairs(grid.rows or {}) do
    local cells = {}
    for i = 2, #row do
      local v = copy(row[i])
      cells[#cells + 1] = (v:gsub("[\t\r\n]", " "))
    end
    lines[#lines + 1] = table.concat(cells, "\t")
  end
  return lines
end

--- Content for `json`: a single pretty-printed array of objects keyed by the
--- grid's column names. vim.json.encode has no pretty mode, so one object per
--- line keeps files diffable and stream-writable.
---@param grid table
---@return string[]
function M.to_json(grid)
  local copy = grid.to_copy
  local names = {}
  for i = 2, #grid.columns do names[#names + 1] = grid.columns[i] end
  local lines = { "[" }
  for ri, row in ipairs(grid.rows or {}) do
    local obj = {}
    for i = 2, #row do obj[names[i - 1]] = copy(row[i]) end
    local comma = (ri < #(grid.rows or {})) and "," or ""
    lines[#lines + 1] = "  " .. vim.json.encode(obj) .. comma
  end
  lines[#lines + 1] = "]"
  return lines
end

--- Export the tab's grid: pick a format, pick a path (default
--- ./poste-redis-<type>-<timestamp>.<ext>), write, notify. Text tabs have no
--- grid — refused with a notice.
---@param tab table|nil active panel tab
---@return boolean exported
function M.export(tab)
  if not tab or tab.kind ~= "table" or not tab.grid then
    vim.notify("Export needs a result grid (list/set/hash/zset tab)",
      vim.log.levels.WARN, { title = constants.TITLE })
    return false
  end
  if #(tab.grid.rows or {}) == 0 then
    vim.notify("Nothing to export — the grid is empty",
      vim.log.levels.WARN, { title = constants.TITLE })
    return false
  end

  vim.ui.select({ "csv", "tsv", "json" }, {
    prompt = "Export format:",
    format_item = function(item)
      local labels = { csv = "CSV (RFC 4180, quoted)", tsv = "TSV (tab-separated)", json = "JSON (array of objects)" }
      return labels[item] or item
    end,
  }, function(fmt)
    if not fmt then return end
    local default_path = vim.fn.getcwd() .. "/poste-redis-"
      .. (tab.grid.type_name or "result") .. "-" .. os.time() .. "." .. fmt
    vim.ui.input({ prompt = "Export to: ", default = default_path,
      completion = "file" }, function(path)
      if not path or path == "" then return end
      -- writefile does not expand `~` — a typed `~/exports/x.csv` failed with
      -- "no such directory" while completion suggested it as a valid target
      path = vim.fn.expand(path)
      local lines = M[fmt == "csv" and "to_csv" or fmt == "tsv" and "to_tsv" or "to_json"](tab.grid)
      local ok, err = pcall(vim.fn.writefile, lines, path)
      if not ok then
        vim.notify("Export failed: " .. tostring(err), vim.log.levels.ERROR,
          { title = constants.TITLE })
        return
      end
      local note = ("Exported %d row(s) to %s"):format(#tab.grid.rows, path)
      -- the grid holds at most what the binary returned (max-items); say so
      -- when the source collection was truncated, so partial exports are loud
      if tab.grid.truncated or (tab.grid.total or #tab.grid.rows) > #tab.grid.rows then
        note = note .. string.format(" (grid holds %d of %d element(s) — raise max-items to export all)",
          #tab.grid.rows, tab.grid.total or #tab.grid.rows)
      end
      vim.notify(note, vim.log.levels.INFO, { title = constants.TITLE })
    end)
  end)
  return true
end

return M
