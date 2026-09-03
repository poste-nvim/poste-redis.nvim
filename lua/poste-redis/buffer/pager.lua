--- Page navigation for table tabs: flips `tab.page` (wrapping) and re-renders
--- the active grid page via `buffer/view`.
local state = require("poste-redis.buffer.state")
local view = require("poste-redis.buffer.view")

local M = {}

--- Re-render the active grid tab's current page + re-place the cursor.
local function refresh_page()
  local tab = state.tabs[state.active]
  if not tab or tab.kind ~= "table" then return end
  view.render_grid(tab)
  view.highlight_cell(tab)
  view.position_cursor(tab)
  view.update_winbar()
end

function M.next()
  local tab = state.tabs[state.active]
  if not tab or tab.kind ~= "table" or not tab.num_pages or tab.num_pages <= 1 then return end
  tab.page = tab.page + 1
  if tab.page > tab.num_pages then tab.page = 1 end
  refresh_page()
end

function M.prev()
  local tab = state.tabs[state.active]
  if not tab or tab.kind ~= "table" or not tab.num_pages or tab.num_pages <= 1 then return end
  tab.page = tab.page - 1
  if tab.page < 1 then tab.page = tab.num_pages end
  refresh_page()
end

function M.first()
  local tab = state.tabs[state.active]
  if not tab or tab.kind ~= "table" or not tab.num_pages or tab.num_pages <= 1 then return end
  tab.page = 1
  refresh_page()
end

function M.last()
  local tab = state.tabs[state.active]
  if not tab or tab.kind ~= "table" or not tab.num_pages or tab.num_pages <= 1 then return end
  tab.page = tab.num_pages
  refresh_page()
end

return M
