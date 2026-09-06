--- Pinned header chrome for the key browser (filter bar + separator).
---
--- The browser buffer keeps the two header lines as its lines 1-2 (the search
--- input is a buffer line — see tree.lua). Left alone they scroll away with
--- the tree. This module mirrors those two lines into a borderless float
--- anchored to the browser window's first two TEXT rows: the float is tied to
--- the window, not the buffer text, so it stays pinned while the tree
--- scrolls. Line math on the browser buffer is untouched — the overlay is
--- pure chrome on top of it.
---
--- Lifecycle: render_tree → sync() (create/reposition + mirror). Editing the
--- bar puts the caret on line 1, under the overlay → search_enter hides it,
--- commit/cancel re-render and sync() shows it again. The float dies with the
--- browser window via WinClosed (floats outlive their anchor window) and
--- lazily on the next sync when the buffer is no longer displayed.

local M = {}

local constants = require("poste-redis.constants")
local tree = require("poste-redis.browser.tree")

local fbuf = nil          -- overlay scratch buffer (mirror of header lines 1-2)
local fwin = nil          -- the overlay float window
local anchored_win = nil  -- browser window the float is pinned to

local guard_group = nil

--- Overlay geometry for the browser window: the window's first two TEXT rows,
--- full window width. relative="win" row 0 is the first text row — the
--- anchor's winbar is EXCLUDED from float anchoring (compensating +1 for it
--- put the overlay one row low: the bar duplicated on screen and real rows
--- hid under it). The browser window carries no gutter (number/sign/fold/
--- status columns are cleared on open), so window col 0 is the first text
--- column.
--- @param win number browser window
--- @return table { row, col, width, height } (nvim_open_win config fields)
local function geometry(win)
  return {
    row = 0,
    col = 0,
    width = vim.api.nvim_win_get_width(win),
    height = tree.HEADER_LINES,
  }
end

--- Close the overlay when its anchor window goes away (:q on the browser
--- splits the float loose — it stays valid and would linger on screen), and
--- keep the overlay's rect equal to its anchor's first rows on every resize:
--- a resize landing between syncs (browser auto-width, a neighbor split)
--- used to leave the float WIDER than its anchor — nvim then clamps it back
--- over the neighboring windows, and a float paints above normal windows no
--- matter its z-index, so the stale bar covered the result panel / history
--- sidebar / source rows.
local function ensure_anchor_guard()
  if guard_group then return end
  guard_group = vim.api.nvim_create_augroup("PosteRedisBrowserHeaderBar", { clear = true })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = guard_group,
    callback = function()
      local closed = tonumber(vim.fn.expand("<amatch>"))
      if closed and closed == anchored_win then M.close() end
    end,
  })
  vim.api.nvim_create_autocmd("WinResized", {
    group = guard_group,
    callback = function()
      if not (fwin and vim.api.nvim_win_is_valid(fwin)) then return end
      if not (anchored_win and vim.api.nvim_win_is_valid(anchored_win)) then return end
      local g = geometry(anchored_win)
      local cfg = vim.api.nvim_win_get_config(fwin)
      if cfg.width ~= g.width or cfg.height ~= g.height then
        vim.api.nvim_win_set_config(fwin, {
          relative = "win", win = anchored_win,
          row = g.row, col = g.col, width = g.width, height = g.height,
        })
      end
    end,
  })
end

--- (Re)pin the overlay to the browser window's top and mirror its current
--- header lines into it. No-op while the buffer has no window (the float is
--- dropped — the next sync on a displayed buffer recreates it).
--- @param browser_buf number
--- @param opts? table { plain = boolean|nil } true when line 1 is NOT the
---   search bar (connections-picker hint): render it without the icon
function M.sync(browser_buf, opts)
  if not browser_buf or not vim.api.nvim_buf_is_valid(browser_buf) then return end
  local win = vim.fn.bufwinid(browser_buf)
  if not win or win == -1 then
    M.close()
    return
  end
  ensure_anchor_guard()

  local g = geometry(win)
  if not (fwin and vim.api.nvim_win_is_valid(fwin)) then
    if not (fbuf and vim.api.nvim_buf_is_valid(fbuf)) then
      fbuf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_option_value("buftype", "nofile", { buf = fbuf })
      vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = fbuf })
      vim.api.nvim_set_option_value("swapfile", false, { buf = fbuf })
    end
    fwin = vim.api.nvim_open_win(fbuf, false, {
      relative = "win", win = win,
      row = g.row, col = g.col, width = g.width, height = g.height,
      style = "minimal", border = "none", focusable = false, mouse = false,
      zindex = constants.ZINDEX_BROWSER, noautocmd = true,
    })
    -- Floats inherit window options from the CURRENT window at open time: an
    -- inherited winbar would shift the mirrored bar down a row, wrap would
    -- break the two-row pair. Pin both to what the overlay needs; the winhl
    -- blends the overlay with the tree rows (result/header.lua pattern).
    vim.api.nvim_set_option_value("winbar", "", { win = fwin })
    vim.api.nvim_set_option_value("wrap", false, { win = fwin })
    pcall(vim.api.nvim_set_option_value, "winhl",
      "Normal:PosteRedisBrowserHeaderBar", { win = fwin })
    anchored_win = win
  elseif anchored_win ~= win
      or vim.api.nvim_win_get_config(fwin).row ~= g.row
      or vim.api.nvim_win_get_config(fwin).width ~= g.width then
    vim.api.nvim_win_set_config(fwin, {
      relative = "win", win = win,
      row = g.row, col = g.col, width = g.width, height = g.height,
    })
    anchored_win = win
  end

  -- Mirror the header lines: the browser buffer stays the single source of
  -- truth, the overlay is a view of it.
  local lines = vim.api.nvim_buf_get_lines(browser_buf, 0, tree.HEADER_LINES, false)
  while #lines < tree.HEADER_LINES do lines[#lines + 1] = "" end
  vim.api.nvim_set_option_value("modifiable", true, { buf = fbuf })
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = fbuf })
  if opts and opts.plain then
    -- picker hint row: plain chrome, no search-bar icon (clearing the
    -- namespace keeps a stale icon from a previous tree state)
    tree.clear_search_decoration(fbuf)
  else
    tree.decorate_search_line(fbuf, lines[1], false)
  end
  tree.decorate_separator(fbuf, lines[2])

  -- An edit path may have hidden the overlay and returned without a render
  -- (e.g. search_cancel via <Esc> in insert mode reaches commit-like paths) —
  -- sync always ends visible.
  if vim.api.nvim_win_get_config(fwin).hide then
    vim.api.nvim_win_set_config(fwin, { hide = false })
  end
end

--- Hide the overlay (bar being edited: the caret sits on the line under it).
--- The window stays valid; sync() un-hides.
function M.hide()
  if fwin and vim.api.nvim_win_is_valid(fwin) then
    vim.api.nvim_win_set_config(fwin, { hide = true })
  end
end

--- Drop the overlay (browser window closed). bufhidden=wipe frees the mirror
--- buffer; the next sync rebuilds both.
function M.close()
  local win, buf = fwin, fbuf
  fwin, fbuf, anchored_win = nil, nil, nil
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

--- The overlay's window handle, when it is alive (tests / debugging).
--- @return number|nil
function M.float_win()
  return (fwin and vim.api.nvim_win_is_valid(fwin)) and fwin or nil
end

M._test = {
  geometry = geometry,
  state = function()
    return {
      buf = (fbuf and vim.api.nvim_buf_is_valid(fbuf)) and fbuf or nil,
      win = M.float_win(),
      anchor = anchored_win,
    }
  end,
}

return M
