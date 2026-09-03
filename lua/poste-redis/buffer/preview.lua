--- K float preview for the result panel: a centered float showing the raw
--- JSON of the tab's value (text tabs) or the current cell's value (table
--- tabs). Pure display — mutates nothing; callers pass in the panel state.
local constants = require("poste-redis.constants")
local format = require("poste-redis.format")

local M = {}

local function float(lines, title)
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
  float(lines, (meta and meta.command) or "raw JSON")
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
  if type(raw) == "table" then
    text = format.preview_json(raw)
  else
    text = tostring(raw)
  end
  local lines = {}
  for line in text:gmatch("[^\n]+") do lines[#lines + 1] = line end
  float(lines, (tab.grid.columns[col] or "cell") .. " · row " .. global_row)
end

return M
