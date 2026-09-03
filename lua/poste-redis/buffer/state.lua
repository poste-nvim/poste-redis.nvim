--- Shared mutable state for the result panel. Kept in one place so the
--- feature modules (`buffer/view`, `buffer/search`, `buffer/pager`,
--- `buffer/preview`, `buffer/yank`) and the `buffer.lua` facade can all read
--- it without circular requires: everything depends on state, nothing on the
--- facade.
local M = {}

--- The panel scratch buffer / window (nil when closed).
M.buf = nil
M.win = nil
--- Tabpage the panel window was opened on; show_panel re-homes the window
--- when the active tabpage changes.
M.panel_tabpage = nil

--- Tab list: { { kind="text", lines, meta } | { kind="table", grid, meta, page, ... } }
M.tabs = {}
--- Active tab index (1-based).
M.active = 1
--- Current tab's raw value for K preview.
M.last_value = nil

--- Grid pagination: rows per page.
M.PAGE_SIZE = 50

--- True when both the panel buffer and its window exist.
function M.is_open()
  return M.buf ~= nil and vim.api.nvim_buf_is_valid(M.buf)
    and M.win ~= nil and vim.api.nvim_win_is_valid(M.win)
end

return M
