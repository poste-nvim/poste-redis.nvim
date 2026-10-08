--- Result formatter: turns one `result` event into display lines or a grid.
--- Table-shaped values (Set / List / Hash / Zset, and a plain string so every
--- type edits the same way) become a table grid (kind "table") rendered by
--- poste-redis.result.grid — head fixed, body scrollable, page navigation
--- (poste-db dataset style). The rest (integer / nil / binary / stream /
--- unknown / error) stay a compact text block (kind "text").
local util = require("poste-redis.util")
local constants = require("poste-redis.constants")
local icons = require("poste-redis.icons")

local M = {}

--- Max rows rendered per tab (the binary already caps at --max-items).
local MAX_RENDER_ROWS = 200

--- Max rows kept in a table grid (matches the binary --max-items default so
--- pagination has real work to do).
local GRID_MAX_ROWS = 1000

--- Escape a value for one-line display.
--- @param v any
--- @return string
local function cell(v)
  if v == nil then return "(nil)" end
  if v == vim.NIL then return "(nil)" end
  if type(v) == "boolean" then return v and "true" or "false" end
  if type(v) == "number" then
    if v == math.floor(v) and math.abs(v) < util.INT_EXACT then
      return string.format("%.0f", v)
    end
    -- tostring, not %g: the yank path (util.to_clipboard) renders the same
    -- number with %.14g precision, so a fractional zset score of 1234567.5
    -- was yanked as "1234567.5" while the cell displayed "1.23457e+06" —
    -- six significant digits the user could not see anywhere else.
    return tostring(v)
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
  -- cell(), not tostring(): LuaJIT renders a large double with %.14g, so an
  -- INCR'd microsecond counter displayed as "1.75e+15"
  return { cell(v.value) }
end

local function render_binary(v)
  local bytes = v.bytes or 0
  local lines = { string.format("(binary) %d bytes", bytes) }
  if v.preview and v.preview ~= "" then
    lines[#lines + 1] = "hex: " .. v.preview
  end
  return lines
end

------------------------------------------------------------------------
--- Collection grids (Set / List / Hash / Zset)
------------------------------------------------------------------------

--- Build a grid model for a collection reply.
--- rows[i] holds RAW values with the row index at [1]; rendering/search use
--- grid.to_display, yank/preview use grid.to_copy — the index column is
--- display-only, never part of a copied value. Its header shows the key's
--- icon + type (e.g. " string"), colored like the browser tree icon.
--- @param columns string[] header cells (includes the type label column)
--- @param rows table[][] raw cell values, rows[i][1] = row index
--- @param total number  element count reported by the binary
--- @param truncated boolean
--- @param right_align number[]  extra right-aligned columns (1-based, beyond the index)
--- @param type_name string  redis type for the header label + color
--- @return table grid
local function new_grid(columns, rows, total, truncated, right_align, type_name)
  return {
    columns = columns,
    rows = rows,
    total = total,
    truncated = truncated,
    right_align = right_align or {},
    type_name = type_name,
    type_hl = icons.type_hl(type_name),
    to_display = cell,
    to_copy = util.to_clipboard,
  }
end

--- Single-column collections (list / set): `type | value`.
local function build_list_grid(v, type_name)
  local items = v.value or {}
  local total = v.len or #items
  local shown = math.min(#items, GRID_MAX_ROWS)
  local rows = {}
  for i = 1, shown do
    rows[i] = { i, items[i] }
  end
  return new_grid({ icons.type_label(type_name), "value" }, rows, total,
    v.truncated or shown < total, nil, type_name)
end

--- Key/value collections (hash / map): `type | field | value`.
local function build_hash_grid(v, type_name)
  local entries = v.entries or {}
  local total = v.len or #entries
  local shown = math.min(#entries, GRID_MAX_ROWS)
  local rows = {}
  for i = 1, shown do
    local e = entries[i]
    rows[i] = { i, e[1], e[2] }
  end
  return new_grid({ icons.type_label(type_name), "field", "value" }, rows, total,
    v.truncated or shown < total, nil, type_name)
end

--- Sorted-set: `type | member | score` with the score column right-aligned.
local function build_zset_grid(v, type_name)
  local items = v.value or {}
  local total = v.len or #items
  local shown = math.min(#items, GRID_MAX_ROWS)
  local rows = {}
  for i = 1, shown do
    local it = items[i]
    rows[i] = { i, it.member or "", it.score }
  end
  return new_grid({ icons.type_label(type_name), "member", "score" }, rows, total,
    v.truncated or shown < total, { 3 }, type_name)
end

--- Strings render through the same grid so every type is edited/navigated
--- the same way: `type | value` with a single row.
local function build_string_grid(v)
  local s = v.value
  if type(s) ~= "string" then s = cell(s) end
  return new_grid({ icons.type_label("string"), "value" }, { { 1, s } },
    1, v.truncated, nil, "string")
end

local GRID_BUILDERS = {
  list = build_list_grid,
  set = build_list_grid,
  hash = build_hash_grid,
  map = build_hash_grid,
  zset = build_zset_grid,
  string = build_string_grid,
}

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

--- Text renderers, consulted only for types with no GRID_BUILDERS entry —
--- which is why "string" is absent here: it renders as a one-row grid.
local RENDERERS = {
  ["nil"] = render_nil,
  integer = render_integer,
  binary = render_binary,
  stream = render_stream,
  unknown = render_unknown,
}

-----------------------------------------------------------------------
--- Public API
-----------------------------------------------------------------------

--- Did this command fail, and with what text?
---
--- `status` is the verdict and `error` is its explanation, and they are separate
--- fields on the way here: `redis_executor` reports an empty command with
--- `status: ""` plus a message, and it is the CLI that stamps `status = "error"`
--- whenever a message is present (`redis_exec.rs`, `redis_session.rs`). The plugin
--- must not assume that stamp survives a version change, so either field alone
--- counts as a failure — with one exception the caller has to name:
---
--- A history entry stands for a whole batch. Its `status` is the batch verdict
--- ("some command failed") while its `value` and `error` belong to the FIRST
--- command (see `runner.on_done`), so a batch whose later command failed must keep
--- replaying the result the user saw at run time. Those events arrive with
--- `batch = true`, which makes the verdict alone non-decisive; a message still is.
---
--- @param event table|nil { status, error, batch? }
--- @return boolean failed, string|nil text nil text means "no reason was given"
function M.command_failed(event)
  if type(event) ~= "table" then return false, nil end
  -- `vim.NIL` is a truthy userdata and an empty string says nothing; neither is
  -- a message, and `format_error` supplies the placeholder.
  local text = event.error
  if text == vim.NIL or text == "" then text = nil end
  return text ~= nil or (event.status == "error" and event.batch ~= true), text
end

--- Format a single result event into a tab payload.
--- Returns kind "table" (grid) for collections, kind "text" (lines) otherwise.
--- @param event table  { seq, command, status, latency_ms, value, error, batch? }
--- @return table { kind = "text"|"table", lines = string[]|nil, grid = table|nil, meta = table }
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

  -- A rejected command must not fall through to the value renderer: the binary
  -- sends `{"type":"nil"}` beside every error, so the old conjunction of
  -- "message present AND status is error" printed `(nil)` — indistinguishable
  -- from a genuine nil reply — for any failure that arrived without a stamp,
  -- while the sign column and the winbar already showed ✘.
  local failed, err_text = M.command_failed(event)
  if failed then
    meta.error = err_text
    return { kind = "text", lines = M.format_error(err_text, meta.command), meta = meta }
  end

  local value = event.value
  if type(value) == "table" and value.type then
    local build = GRID_BUILDERS[value.type]
    if build then
      local ok, grid = pcall(build, value, value.type)
      if ok then
        return { kind = "table", grid = grid, meta = meta }
      end
      return { kind = "text", lines = { "  (failed to render value: " .. tostring(grid) .. ")" }, meta = meta }
    end
    local render = RENDERERS[value.type] or render_unknown
    local ok, rendered = pcall(render, value)
    if ok then
      return { kind = "text", lines = rendered, meta = meta }
    end
    return { kind = "text", lines = { "  (failed to render value: " .. tostring(rendered) .. ")" }, meta = meta }
  end
  return { kind = "text", lines = { cell(value) }, meta = meta }
end

--- Format an error message into panel lines.
--- The command line passes through escape_for_line: a binary-safe key
--- (`GET "a\nb"` — the decoded form carries a real newline) must stay ONE
--- buffer line — nvim_buf_set_lines rejects embedded newlines, and an
--- unescaped command crashed the panel render instead of showing the error.
--- @param err string
--- @param command string|nil
--- @return string[]
function M.format_error(err, command)
  local lines = { "ERROR" }
  if command and command ~= "" then
    lines[#lines + 1] = "  command: " .. util.escape_for_line(command)
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

--- Status summary line for the winbar (e.g. `2 ms · OK`). Simple replies
--- carry the value itself in `status` (exec summarizes GET etc. verbatim),
--- so for string values only the length is shown — a long payload has no
--- business in a winbar.
--- @param event table
--- @return string
function M.status_summary(event)
  local ms = event and event.latency_ms
  local lat = ms and util.format_latency(ms) or ""
  local status = (event and event.status) or ""
  if status == "error" or (event and event.error) then return "✘ " .. lat end
  local v = event and event.value
  if v and v.type == "string" and type(v.value) == "string" then
    -- `len` is the reply's real size and `value` is what the binary was
    -- willing to print (--max-bytes): reporting `#v.value` called the cap
    -- the size, so a 50 MB string read "len 65536" and looked complete.
    local shown = #v.value
    local total = tonumber(v.len) or shown
    status = total > shown and ("len " .. total .. ", truncated") or ("len " .. shown)
  end
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
  RENDERERS = RENDERERS,
  GRID_BUILDERS = GRID_BUILDERS,
  MAX_RENDER_ROWS = MAX_RENDER_ROWS,
  GRID_MAX_ROWS = GRID_MAX_ROWS,
}

return M
