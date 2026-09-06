--- poste-redis.result.header — floating fixed header for the grid panel.
--- A 1-line float pinned to the top of the result window that follows
--- horizontal scroll (poste-db dataset style): the body scrolls underneath
--- while the column names stay in view. No poste deps.
local M = {}

local constants = require("poste-redis.constants")

local float_buf = nil
local float_win = nil
local cache_leftcol = nil
local cache_width = nil
local cache_header = nil
local cache_type_hl = nil
local cache_icon_hl = nil
local type_ns = vim.api.nvim_create_namespace("poste_redis_grid_header_type")
local sort_ns = vim.api.nvim_create_namespace("poste_redis_grid_header_sort")
local SEP = "│"

local last_args = nil   -- { win, header, index, type_hl, icon_hl } of the last render
local resize_group = nil

--- Per-char display index of a line: byte range + display range per char.
--- CJK/emoji never split; `│` separators are just 1-width chars here.
--- @param line string
--- @return table[] index
local function build_index(line)
  local idx = {}
  local disp = 0
  local byte = 1
  local ok, chars = pcall(vim.fn.split, line, "\\zs")
  if not ok then chars = {} end
  for _, ch in ipairs(chars) do
    local bw = #ch
    local dw = vim.fn.strdisplaywidth(ch)
    if dw == 0 then dw = 1 end
    idx[#idx + 1] = { bs = byte, be = byte + bw - 1, ds = disp, de = disp + dw }
    disp = disp + dw
    byte = byte + bw
  end
  return idx
end

--- Slice a padded header line to the visible viewport (char-level display
--- math keeps multibyte names aligned; chars straddling the window edges
--- become blanks so no phantom separators appear).
--- @param leftcol number  display offset of viewport left edge
--- @param win_width number  viewport width in display columns
--- @param padded_header string  header with left padding
--- @param index table[]  per-char index from build_index()
--- @return string
local function slice_to_win(leftcol, win_width, padded_header, index)
  if not padded_header or not index then return string.rep(" ", leftcol) end
  local right_edge = leftcol + win_width
  local parts = {}
  for _, c in ipairs(index) do
    if c.de <= leftcol then goto continue end
    if c.ds >= right_edge then break end
    local text
    if c.ds < leftcol then
      text = string.rep(" ", math.min(c.de, right_edge) - leftcol)
    elseif c.de > right_edge then
      text = string.rep(" ", right_edge - c.ds)
    else
      text = padded_header:sub(c.bs, c.be)
    end
    parts[#parts + 1] = text
    ::continue::
  end
  if #parts == 0 then return "" end
  return table.concat(parts)
end

--- Close the header float and reset the slice cache.
function M.close()
  if float_win and vim.api.nvim_win_is_valid(float_win) then
    pcall(vim.api.nvim_win_close, float_win, true)
  end
  if float_buf and vim.api.nvim_buf_is_valid(float_buf) then
    pcall(vim.api.nvim_buf_delete, float_buf, { force = true })
  end
  float_win = nil
  float_buf = nil
  cache_leftcol = nil
  cache_width = nil
  cache_header = nil
  cache_type_hl = nil
  cache_icon_hl = nil
end

--- Highlight the type cell (first column, e.g. " string") within a sliced
--- header line: the byte range between the first two `│` separators. Only
--- meaningful when the viewport starts at column 0 (leftcol == 0); clamped
--- to the line so a partial slice never errors.
local function apply_type_hl(bf, text, type_hl)
  if not type_hl or not bf or not vim.api.nvim_buf_is_valid(bf) then return end
  local p1 = text:find(SEP, 1, true)
  if not p1 then return end
  local p2 = text:find(SEP, p1 + #SEP, true)
  if not p2 or p2 <= p1 + #SEP then return end
  vim.api.nvim_buf_clear_namespace(bf, type_ns, 0, -1)
  vim.api.nvim_buf_set_extmark(bf, type_ns, 0, p1 + #SEP - 1, {
    end_row = 0,
    end_col = math.max(p1 + #SEP - 1, p2 - 2),
    hl_group = type_hl,
    priority = 100,
  })
end

--- Highlight the column-sort icon (▲/▼ after a sorted column's name) in a
--- sliced header line. Byte positions come from the UNSLICED padded header
--- (sort.icon_range), which coincide with the slice only at leftcol == 0 —
--- the same constraint the type-cell highlight already lives with.
local function apply_sort_hl(bf, icon_hl)
  if not bf or not vim.api.nvim_buf_is_valid(bf) then return end
  vim.api.nvim_buf_clear_namespace(bf, sort_ns, 0, -1)
  if not icon_hl then return end
  vim.api.nvim_buf_add_highlight(bf, sort_ns, "PosteRedisResultSort", 0,
    icon_hl[1], icon_hl[2])
end

--- Keep the header float in step with layout changes: on any resize,
--- re-render from the cached args for the anchor window's fresh width and
--- scroll (leftcol) — or drop the float when its anchor is gone.
local function ensure_resize_guard()
  if resize_group then return end
  resize_group = vim.api.nvim_create_augroup("PosteRedisResultHeaderResize", { clear = true })
  vim.api.nvim_create_autocmd("WinResized", {
    group = resize_group,
    callback = function()
      if not (float_win and vim.api.nvim_win_is_valid(float_win)) then return end
      local a = last_args
      if not a or not a.win or not vim.api.nvim_win_is_valid(a.win) then
        M.close()
        return
      end
      M.update(a.win, a.header, a.index, a.type_hl, a.icon_hl)
    end,
  })
end

--- Re-render the header float for the current viewport of `win`. The float's
--- width must track its anchor window on EVERY layout change, not just on
--- grid renders: opening the browser (or any split) narrows the panel
--- between renders, and a too-wide float overhangs into the neighbor — a
--- float paints above normal windows at any z-index, so the stale header
--- covered a browser row (WinResized re-renders from the cached args).
--- @param win number  the result window the float is anchored to
--- @param padded_header string  full padded header line (with left padding)
--- @param index table[]|nil  cached per-char index (built when nil)
--- @param type_hl string|nil  highlight for the type cell (first column)
--- @param icon_hl table|nil  { start, end_ } byte range of the sort icon
function M.update(win, padded_header, index, type_hl, icon_hl)
  if not win or not vim.api.nvim_win_is_valid(win) then M.close(); return end
  if not padded_header then M.close(); return end
  index = index or build_index(padded_header)
  ensure_resize_guard()

  local win_width = vim.api.nvim_win_get_width(win)
  if win_width <= 0 then return end
  local leftcol
  if vim.api.nvim_get_current_win() == win then
    leftcol = vim.fn.winsaveview().leftcol
  else
    leftcol = vim.api.nvim_win_call(win, function()
      return vim.fn.winsaveview().leftcol
    end)
  end

  if leftcol == cache_leftcol and win_width == cache_width
      and padded_header == cache_header and type_hl == cache_type_hl
      and icon_hl == cache_icon_hl then
    return
  end
  cache_type_hl = type_hl
  cache_icon_hl = icon_hl
  cache_leftcol = leftcol
  cache_width = win_width
  cache_header = padded_header

  local text = slice_to_win(leftcol, win_width, padded_header, index)
  -- last_args is set at BOTH exits below: the recreate path runs M.close(),
  -- which resets the cache — an assignment made before it would be lost by
  -- the time the float is back (and the resize guard would see nil)
  local function remember_args()
    last_args = { win = win, header = padded_header, index = index,
      type_hl = type_hl, icon_hl = icon_hl }
  end

  if float_buf and vim.api.nvim_buf_is_valid(float_buf) then
    vim.api.nvim_set_option_value("modifiable", true, { buf = float_buf })
    vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, { text })
    vim.api.nvim_set_option_value("modifiable", false, { buf = float_buf })
    if leftcol == 0 then
      apply_type_hl(float_buf, text, type_hl)
      apply_sort_hl(float_buf, icon_hl)
    end
    if float_win and vim.api.nvim_win_is_valid(float_win)
        and vim.api.nvim_win_get_width(float_win) ~= win_width then
      vim.api.nvim_win_set_config(float_win, { width = win_width })
    end
    remember_args()
    return
  end

  M.close()
  float_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = float_buf })
  vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, { text })
  vim.api.nvim_set_option_value("modifiable", false, { buf = float_buf })
  if leftcol == 0 then
    apply_type_hl(float_buf, text, type_hl)
    apply_sort_hl(float_buf, icon_hl)
  end
  float_win = vim.api.nvim_open_win(float_buf, false, {
    relative = "win",
    win = win,
    row = 0,
    col = 0,
    width = win_width,
    height = 1,
    style = "minimal",
    border = "none",
    focusable = false,
    zindex = constants.ZINDEX_RESULT,
    noautocmd = true,
  })
  pcall(vim.api.nvim_set_option_value, "winhl", "Normal:PosteRedisResultHeader", { win = float_win })
  remember_args()
end

M._test = {
  build_index = build_index,
  slice_to_win = slice_to_win,
  close = M.close,
  float_win = function()
    return (float_win and vim.api.nvim_win_is_valid(float_win)) and float_win or nil
  end,
}

return M
