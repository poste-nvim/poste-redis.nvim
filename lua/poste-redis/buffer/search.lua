--- In-grid search for table tabs: case-insensitive substring over cell
--- values. Search state lives on the tab (`search_text` / `search_matches` /
--- `search_idx`); matches are drawn by `buffer/view.apply_search_highlights`,
--- and jumping moves the cell cursor, flipping pages when the match is off-page.
local state = require("poste-redis.buffer.state")
local view = require("poste-redis.buffer.view")
local constants = require("poste-redis.constants")
local grid = require("poste-redis.result.grid")

local M = {}

local function compute_search(tab)
  tab.search_matches = {}
  tab.search_idx = 0
  if not tab.search_text or tab.search_text == "" then return end
  tab.search_matches = grid.compute_matches(tab.grid, tab.search_text)
end

function M.jump(tab, idx)
  local m = tab.search_matches[idx]
  if not m then return end
  tab.search_idx = idx
  local target_page = math.ceil(m.row / tab.page_size)
  if target_page ~= tab.page then
    tab.page = target_page
    view.render_grid(tab)
  end
  local vis_row = m.row - (tab.page - 1) * tab.page_size
  tab.cursor.row = vis_row
  tab.cursor.col = m.col
  view.highlight_cell(tab)
  view.position_cursor(tab)
  view.apply_search_highlights(tab)
  view.update_winbar()
end

--- Interactive search over grid cell values (case-insensitive substring).
function M.show()
  local tab = state.tabs[state.active]
  if not tab or tab.kind ~= "table" then return end
  vim.ui.input({ prompt = "Search in results: ", default = tab.search_text or "" }, function(text)
    if text == nil then return end
    tab.search_text = text
    compute_search(tab)
    if #tab.search_matches > 0 then
      M.jump(tab, 1)
    else
      view.apply_search_highlights(tab)
      view.update_winbar()
      if text ~= "" then
        vim.notify("No matches for '" .. text .. "'", vim.log.levels.INFO, { title = constants.TITLE })
      end
    end
  end)
end

function M.next()
  local tab = state.tabs[state.active]
  if not tab or tab.kind ~= "table" or #tab.search_matches == 0 then return end
  M.jump(tab, (tab.search_idx % #tab.search_matches) + 1)
end

function M.prev()
  local tab = state.tabs[state.active]
  if not tab or tab.kind ~= "table" or #tab.search_matches == 0 then return end
  local idx = ((tab.search_idx - 2 + #tab.search_matches) % #tab.search_matches) + 1
  M.jump(tab, idx)
end

return M
