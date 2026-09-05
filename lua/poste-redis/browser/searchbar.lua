--- The browser's search bar (header line 1) + its navigation clamp.
---
--- <leader>/ enters search state: focus the bar on line 1 in insert mode,
--- <CR> runs async.search on the current db, empty + <CR> clears, <Esc>
--- cancels. `/` is untouched so nvim's own buffer search keeps working.
--- While the bar is edited the pinned header overlay hides (the caret needs
--- line 1) and the cursor clamp is lifted; commit/cancel restore both.
---
--- Rendering goes through async.render_hook (installed by the facade), so
--- this module never needs to know how drawing works.
local tree = require("poste-redis.browser.tree")
local async = require("poste-redis.browser.async")
local state = require("poste-redis.browser.state")
local header_bar = require("poste-redis.browser.header_bar")

local M = {}

local search_commit  -- forward declarations (AGENTS.md: local fn hoisting)
local search_cancel

--- Keep the cursor off the two pinned header rows (filter bar + separator):
--- they render under the overlay float, so a cursor there is invisible and
--- can do nothing. Normal navigation bottoms out at the first tree row; the
--- bar itself is only reachable through <leader>/ (search_enter), which is
--- why the clamp skips while search_active.
function M.clamp_cursor()
  if state.search_active then return end
  local buf = state.browser_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  local win = vim.fn.bufwinid(buf)
  if not win or win == -1 then return end
  local cur = vim.api.nvim_win_get_cursor(win)
  local first_row = tree.HEADER_LINES + 1
  if cur[1] >= first_row then return end
  -- clamp only onto an EXISTING tree row: an empty db renders just the two
  -- header lines, and there is no tree row to park the cursor on
  if vim.api.nvim_buf_line_count(buf) < first_row then return end
  local line_text = vim.api.nvim_buf_get_lines(buf, tree.HEADER_LINES, first_row, false)[1] or ""
  vim.api.nvim_win_set_cursor(win, { first_row, math.min(cur[2], #line_text) })
end

--- The committed query shown on the bar: the icon is virt text added by
--- tree.decorate_search_line, never buffer text.
--- @return string
function M.bar_text()
  return state.search_query
end

--- <leader>/: enter search state — focus the search bar on line 1, insert
--- mode (typed text lands after the fixed icon prefix, NOT the command
--- line). <CR> runs async.search on the current db and loses focus; empty +
--- <CR> clears the search; <Esc> cancels.
function M.enter()
  local buf = state.browser_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  if state.conn_picker.active then return end  -- no bar before a context is chosen
  local win = vim.fn.bufwinid(buf)
  if win ~= -1 then vim.api.nvim_set_current_win(win) end

  state.search_active = true
  tree.set_header_line(buf, state.search_query, 1)
  -- The icon is idle-only virt text. While editing it is dropped so the
  -- caret (at the true EOL) can never sit on or before it — the bar is
  -- just the query, and insert mode is entered automatically.
  tree.decorate_search_line(buf, state.search_query, true)
  -- the pinned overlay would cover the caret row: drop it until commit
  header_bar.hide()
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.keymap.set("i", "<CR>", search_commit, { buffer = buf, silent = true })
  vim.keymap.set("i", "<Esc>", search_cancel, { buffer = buf, silent = true })
  -- Land on the search line FIRST: :startinsert! works like "A" (append at the
  -- EOL of the line the caret is on), so without this it would put the tree
  -- row under the cursor into insert mode instead. From (1,0) it reaches the
  -- search line's TRUE EOL and Insert mode starts after this function returns
  -- (no i/A needed). normal! A must not be used — insert mode entered via
  -- :normal does not survive a mapping callback (:help :startinsert).
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd("startinsert!")
end

--- Parse the query out of the search bar line: trim whitespace. The icon is
--- virt text, never in the buffer, but a stray icon (pasted, or a stale
--- pre-virt bar) is still stripped defensively — the icon must never leak
--- into a query.
--- @param line string
--- @return string
function M.parse_line(line)
  line = line or ""
  -- strip the fixed icon prefix repeatedly (an already-doubled bar repairs
  -- itself), plus a bare icon alone from a deleted separator space — the
  -- icon must never survive into the committed query
  while line:sub(1, #tree.SEARCH_PREFIX) == tree.SEARCH_PREFIX do
    line = line:sub(#tree.SEARCH_PREFIX + 1)
  end
  if line:sub(1, #tree.SEARCH_ICON) == tree.SEARCH_ICON then
    line = line:sub(#tree.SEARCH_ICON + 1)
  end
  line = line:gsub("^%s+", "")
  return (line:gsub("%s+$", ""))
end

--- <CR> in the search bar: read the query, run async.search, return to tree.
-- NOTE: assigned (not `local function`) so it fills the forward-declared
-- local `search_commit` that enter() captured — a second `local` here would
-- shadow it with nil (AGENTS.md local-fn hoisting pitfall).
function search_commit()
  local buf = state.browser_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
  local query = M.parse_line(line)
  vim.cmd.stopinsert()
  vim.keymap.del("i", "<CR>", { buffer = buf })
  vim.keymap.del("i", "<Esc>", { buffer = buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  state.search_active = false
  if query == "" then
    M.clear()
    return
  end
  state.search_query = query
  if state.current_db_node and state.current_conn then
    async.search(state.current_db_node, state.current_conn.url, state.current_conn.name, query)
  end
  if state.render then state.render() end
  M.clamp_cursor()  -- the caret was on the bar row: walk it back to the tree
end

--- <Esc> in the search bar: cancel, clear any results, restore the tree.
-- NOTE: assigned (not `local function`) — see search_commit.
function search_cancel()
  local buf = state.browser_buf
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.cmd.stopinsert()
    vim.keymap.del("i", "<CR>", { buffer = buf })
    vim.keymap.del("i", "<Esc>", { buffer = buf })
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  end
  M.clear()  -- also walks the caret off the pinned bar row (clamp)
end

--- Exposed for tests (M._test.search_commit).
M.commit = search_commit
--- Exposed for tests (M._test.search_cancel).
M.cancel = search_cancel

--- Clear any active search results and restore the tree. The facade exposes
--- this as M.search_clear (public <Esc> binding + programmatic use).
--- Renders only when the display actually changes: async.search_clear
--- schedules its own restoring render when results existed, and a no-op
--- clear (no results, bar idle) leaves the tree untouched.
function M.clear()
  local was_active = state.search_active
  state.search_active = false
  state.search_query = ""
  local node = state.current_db_node
  local had_results = node ~= nil and node._search_results ~= nil
  local needs_render = was_active or had_results
  if node then
    async.search_clear(node)
  end
  -- synchronous restore: a debounced render made search_clear's tree
  -- restoration lag a frame behind the call (visible as stale rows)
  if needs_render and state.render then state.render() end
  M.clamp_cursor()  -- the caret may sit on the pinned bar row after <CR>/<Esc>
end

return M
