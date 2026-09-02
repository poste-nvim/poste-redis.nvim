--- poste-redis.result.header — floating fixed header for the grid panel.
--- A 1-line float pinned to the top of the result window that follows
--- horizontal scroll (poste-db dataset style): the body scrolls underneath
--- while the column names stay in view. No poste deps.
local M = {}

local float_buf = nil
local float_win = nil
local cache_leftcol = nil
local cache_width = nil
local cache_header = nil

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
end

--- Re-render the header float for the current viewport of `win`.
--- @param win number  the result window the float is anchored to
--- @param padded_header string  full padded header line (with left padding)
--- @param index table[]|nil  cached per-char index (built when nil)
function M.update(win, padded_header, index)
  if not win or not vim.api.nvim_win_is_valid(win) then M.close(); return end
  if not padded_header then M.close(); return end
  index = index or build_index(padded_header)

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
      and padded_header == cache_header then
    return
  end
  cache_leftcol = leftcol
  cache_width = win_width
  cache_header = padded_header

  local text = slice_to_win(leftcol, win_width, padded_header, index)

  if float_buf and vim.api.nvim_buf_is_valid(float_buf) then
    vim.api.nvim_set_option_value("modifiable", true, { buf = float_buf })
    vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, { text })
    vim.api.nvim_set_option_value("modifiable", false, { buf = float_buf })
    if float_win and vim.api.nvim_win_is_valid(float_win)
        and vim.api.nvim_win_get_width(float_win) ~= win_width then
      vim.api.nvim_win_set_config(float_win, { width = win_width })
    end
    return
  end

  M.close()
  float_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = float_buf })
  vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, { text })
  vim.api.nvim_set_option_value("modifiable", false, { buf = float_buf })
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
    zindex = 40,
    noautocmd = true,
  })
  pcall(vim.api.nvim_set_option_value, "winhl", "Normal:PosteRedisResultHeader", { win = float_win })
end

M._test = {
  build_index = build_index,
  slice_to_win = slice_to_win,
  close = M.close,
}

return M
