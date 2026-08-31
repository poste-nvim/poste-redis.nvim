--- Result formatter: turns one `result` event into display lines.
--- Mirrors redis-cli's rendering (OK / (nil) / "value" / numbered lists /
--- field-value tables) but stays a compact text block — the M1 panel is a
--- self-built single-buffer + tabs (EXECUTION-PLAN D2), no dataset grid.
local util = require("poste-redis.util")
local constants = require("poste-redis.constants")

local M = {}

--- Max rows rendered per tab (the binary already caps at --max-items).
local MAX_RENDER_ROWS = 200

--- Escape a value for one-line display.
--- @param v any
--- @return string
local function cell(v)
  if v == nil then return "(nil)" end
  if v == vim.NIL then return "(nil)" end
  if type(v) == "boolean" then return v and "true" or "false" end
  if type(v) == "number" then
    if v == math.floor(v) and math.abs(v) < 1e15 then
      return string.format("%.0f", v)
    end
    return string.format("%g", v)
  end
  if type(v) == "table" then
    local ok, s = pcall(vim.json.encode, v)
    return ok and s or vim.inspect(v)
  end
  return util.escape_for_line(tostring(v))
end

-----------------------------------------------------------------------
--- Scalar renderers
-----------------------------------------------------------------------

local function render_nil(_)
  return { "(nil)" }
end

local function render_integer(v)
  return { tostring(v.value) }
end

local function render_string(v)
  local s = v.value
  if type(s) ~= "string" then s = cell(s) end
  local lines = { '"' .. s .. '"' }
  if v.truncated then
    lines[#lines + 1] = string.format("… %d bytes total, %d shown", v.len or 0, #s)
  elseif v.len then
    lines[#lines + 1] = string.format("(%d bytes)", v.len)
  end
  return lines
end

local function render_binary(v)
  local bytes = v.bytes or 0
  local lines = { string.format("(binary) %d bytes", bytes) }
  if v.preview and v.preview ~= "" then
    lines[#lines + 1] = "hex: " .. v.preview
  end
  return lines
end

-----------------------------------------------------------------------
--- Collection renderers
-----------------------------------------------------------------------

--- Generic two-column table with a fixed left header.
--- @param rows table[]  { key, value } pairs
--- @param k_header string
--- @param v_header string
--- @return string[] lines, number rows_rendered, number rows_total
local function render_pair_table(rows, k_header, v_header)
  local shown = math.min(#rows, MAX_RENDER_ROWS)
  local key_w = util.display_width(k_header)
  local val_w = util.display_width(v_header)
  for i = 1, shown do
    local r = rows[i]
    key_w = math.max(key_w, util.display_width(cell(r[1])))
    val_w = math.max(val_w, util.display_width(cell(r[2])))
  end
  key_w = math.min(key_w, 40)
  val_w = math.min(val_w, 80)
  local sep = " │ "
  local top = "┌" .. string.rep("─", key_w) .. "┬" .. string.rep("─", val_w) .. "┐"
  local border = "├" .. string.rep("─", key_w) .. "┼" .. string.rep("─", val_w) .. "┤"
  local bot = "└" .. string.rep("─", key_w) .. "┴" .. string.rep("─", val_w) .. "┘"
  local lines = { top }
  lines[#lines + 1] = "│" .. util.pad_right(k_header, key_w) .. sep .. util.pad_right(v_header, val_w) .. "│"
  lines[#lines + 1] = border
  for i = 1, shown do
    local r = rows[i]
    local k = util.truncate_display(cell(r[1]), key_w)
    local v = util.truncate_display(cell(r[2]), val_w)
    lines[#lines + 1] = "│" .. util.pad_right(k, key_w) .. sep .. util.pad_right(v, val_w) .. "│"
  end
  lines[#lines + 1] = bot
  if shown < #rows then
    lines[#lines + 1] = string.format("… %d more rows not rendered", #rows - shown)
  end
  return lines, shown, #rows
end

--- Numbered list (redis-cli style: `1) "item"`).
local function render_list(v)
  local items = v.value or {}
  local total = v.len or #items
  if #items == 0 then return { "(empty list)" } end
  local rendered = math.min(#items, MAX_RENDER_ROWS)
  local num_w = util.display_width(string.format("%.0f", rendered))
  local lines = {}
  for i = 1, rendered do
    lines[#lines + 1] = util.pad_left(string.format("%.0f", i), num_w) .. ") " .. cell(items[i])
  end
  if rendered < total then
    lines[#lines + 1] = string.format("… %d more not shown", total - rendered)
  end
  if v.truncated then
    lines[#lines + 1] = string.format("(%d elements total, server output capped)", total)
  end
  return lines
end

local function render_hash(v)
  local rows = v.entries or {}
  local total = v.len or #rows
  if #rows == 0 then return { "(empty hash)" } end
  local lines, shown, _ = render_pair_table(rows, "field", "value")
  if v.truncated or shown < total then
    lines[#lines + 1] = string.format("(%d fields total)", total)
  end
  return lines
end

local function render_zset(v)
  local items = v.value or {}
  local total = v.len or #items
  if #items == 0 then return { "(empty zset)" } end
  local rows = {}
  for i, it in ipairs(items) do
    rows[#rows + 1] = { it.member or "", util.escape_for_line(tostring(it.score or 0)) }
  end
  local lines, shown, _ = render_pair_table(vim.list_slice(rows, 1, MAX_RENDER_ROWS), "member", "score")
  if v.truncated or shown < total then
    lines[#lines + 1] = string.format("(%d members total)", total)
  end
  return lines
end

local function render_stream(v)
  local items = v.value or {}
  local total = v.len or #items
  if #items == 0 then return { "(empty stream)" } end
  local lines = {}
  for i = 1, math.min(#items, MAX_RENDER_ROWS) do
    local it = items[i]
    lines[#lines + 1] = string.format("[%d] %s", i, it.id or "(id)")
    for _, f in ipairs(it.fields or {}) do
      lines[#lines + 1] = string.format("       %s = %s", cell(f[1]), cell(f[2]))
    end
  end
  if v.truncated or math.min(#items, MAX_RENDER_ROWS) < total then
    lines[#lines + 1] = string.format("(%d entries total)", total)
  end
  return lines
end

local function render_unknown(v)
  return { cell(v.value) }
end

local RENDERERS = {
  ["nil"] = render_nil,
  integer = render_integer,
  string = render_string,
  binary = render_binary,
  list = render_list,
  set = render_list,
  hash = render_hash,
  map = render_hash,
  zset = render_zset,
  stream = render_stream,
  unknown = render_unknown,
}

-----------------------------------------------------------------------
--- Public API
-----------------------------------------------------------------------

--- Format a single result event into lines + metadata.
--- @param event table  { seq, command, status, latency_ms, value, error }
--- @return table { lines = string[], meta = table }
function M.format_result(event)
  event = event or {}
  local meta = {
    seq = event.seq,
    command = event.command or "",
    status = event.status or "",
    latency_ms = event.latency_ms,
    error = event.error,
    value = event.value,
    dangerous = M.is_dangerous_command(event.command or ""),
  }

  local lines = {}
  if event.error and event.status == "error" then
    meta.error = event.error
    lines = M.format_error(event.error, meta.command)
    return { lines = lines, meta = meta }
  end

  local value = event.value
  if type(value) == "table" and value.type then
    local render = RENDERERS[value.type] or render_unknown
    local ok, rendered = pcall(render, value)
    if ok then
      lines = rendered
    else
      lines = { "  (failed to render value: " .. tostring(rendered) .. ")" }
    end
  elseif type(value) ~= "table" then
    lines = { cell(value) }
  else
    lines = { cell(value) }
  end
  return { lines = lines, meta = meta }
end

--- Format an error message into panel lines.
--- @param err string
--- @param command string|nil
--- @return string[]
function M.format_error(err, command)
  local lines = { "ERROR" }
  if command and command ~= "" then
    lines[#lines + 1] = "  command: " .. command
  end
  local text = tostring(err or "(unknown error)")
  for _, part in ipairs(vim.split(text, "\n", { plain = true })) do
    lines[#lines + 1] = "  " .. util.escape_for_line(part)
  end
  return lines
end

--- Pretty JSON preview for the `K` raw-value action.
--- @param value table|any  the raw `value` object (or a full event)
--- @return string
function M.preview_json(value)
  local ok, s = pcall(vim.json.encode, value, { indent = "  ", sparse_array = true })
  if not ok then return tostring(value) end
  return s
end

--- Status summary line for the winbar / history (e.g. `2 ms · OK`).
--- @param event table
--- @return string
function M.status_summary(event)
  local ms = event and event.latency_ms
  local lat = ms and util.format_latency(ms) or ""
  local status = (event and event.status) or ""
  if status == "error" or (event and event.error) then return "✘ " .. lat end
  if status == "" then return lat end
  return lat ~= "" and (lat .. " · " .. status) or status
end

--- Is the command a red-line dangerous one (FLUSHALL etc.)? Used for the
--- yellow warning in the panel (red line #5, M1).
--- @param command string
--- @return boolean
function M.is_dangerous_command(command)
  return constants.is_dangerous_command(command)
end

M._test = {
  cell = cell,
  render_pair_table = render_pair_table,
  RENDERERS = RENDERERS,
  MAX_RENDER_ROWS = MAX_RENDER_ROWS,
}

return M
