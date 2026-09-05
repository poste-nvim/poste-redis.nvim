--- K float preview for the result panel: a centered float showing the raw
--- JSON of the tab's value (text tabs) or the current cell's value (table
--- tabs). Pure display — mutates nothing; callers pass in the panel state.
local constants = require("poste-redis.constants")
local format = require("poste-redis.format")
local ui = require("poste-redis.ui")

local M = {}

--- Detect if a string is valid JSON (object or array).
--- @param s string
--- @return boolean
local function is_json_string(s)
  if type(s) ~= "string" then return false end
  local trimmed = s:match("^%s*(.-)%s*$")
  if not trimmed then return false end
  local first = trimmed:sub(1, 1)
  if first ~= "{" and first ~= "[" then return false end
  local ok = pcall(vim.json.decode, trimmed)
  return ok
end

--- Try to pretty-print a JSON string; returns original on failure.
--- @param s string
--- @return string
local function pretty_print_json(s)
  local trimmed = s:match("^%s*(.-)%s*$")
  if not trimmed then return s end
  local ok, decoded = pcall(vim.json.decode, trimmed)
  if not ok then return s end
  local encoded = vim.json.encode(decoded, { indent = "  " })
  return encoded or s
end

local function float(lines, title, filetype)
  ui.centered_float(lines, {
    title = title or "preview",
    width = math.min(
      constants.FLOAT_MAX_WIDTH,
      math.floor(vim.o.columns * constants.FLOAT_WIDTH_RATIO)
    ),
    height = math.min(
      math.floor(vim.o.lines * constants.FLOAT_HEIGHT_RATIO),
      math.max(6, #lines + 2)
    ),
    filetype = filetype,
  })
end

--- Show the raw JSON of a result value in a float.
--- @param value any|nil  raw result value (tab.meta.value)
--- @param meta table|nil  tab meta (title falls back to meta.command)
function M.raw(value, meta)
  if not value then
    vim.notify("No result value to preview", vim.log.levels.INFO, { title = constants.TITLE })
    return
  end
  local lines = {}
  for line in format.preview_json(value):gmatch("[^\n]+") do
    lines[#lines + 1] = line
  end
  float(lines, (meta and meta.command) or "raw JSON", "json")
end

--- Preview the current cell (table tab) or the raw value (text / no tab).
--- @param tab table|nil  active tab
--- @param last_value any|nil  active tab's raw value (text-tab fallback)
function M.cell(tab, last_value)
  if not tab or tab.kind ~= "table" then
    M.raw(last_value, tab and tab.meta)
    return
  end
  local global_row = (tab.page - 1) * tab.page_size + tab.cursor.row
  local row_data = tab.grid.rows[global_row]
  local col = tab.cursor.col
  if not row_data or not row_data[col] then return end
  local raw = row_data[col]
  local text
  local filetype
  if type(raw) == "table" then
    text = format.preview_json(raw)
    filetype = "json"
  else
    text = tostring(raw)
    if is_json_string(text) then
      text = pretty_print_json(text)
      filetype = "json"
    end
  end
  local lines = {}
  for line in text:gmatch("[^\n]+") do lines[#lines + 1] = line end
  float(lines, (tab.grid.columns[col] or "cell") .. " · row " .. global_row, filetype)
end

return M
