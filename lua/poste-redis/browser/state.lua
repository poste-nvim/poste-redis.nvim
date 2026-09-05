--- Shared mutable state for the key browser (the "state.lua at the bottom"
--- shape: every browser/* submodule depends on this, never on each other's
--- internals — that is what keeps the module graph acyclic).
---
--- The browser was one 1100-line file whose locals doubled as a global
--- object graph; the fields moved here unchanged so submodules read and
--- mutate the SAME values (table fields, so writes propagate).
---
--- Scope operations (select_db) and the browser-window re-resolution also
--- live here: they only need the fields below plus scan/tree/async, never
--- the facade or a sibling submodule.
local tree = require("poste-redis.browser.tree")
local scan = require("poste-redis.browser.scan")

local M = {}

-- Window + buffer handles. browser_win goes stale after :q / split churn —
-- resolve it from the buffer instead of trusting the cached handle.
M.browser_buf = nil
M.browser_win = nil

--- line → node map of the last render (tree.render_tree output).
M.line_to_node = {}

--- Width the browser was last opened at: the auto-width floor, so the split
--- never auto-shrinks below what the user asked for on open.
M.opened_width = 30

--- Current scope: one connection, one selected db. The db node is the hidden
--- display root; its children render at the top of the tree.
M.current_conn = nil       -- { name, url } | nil
M.current_db = 0
M.current_db_node = nil    -- tree.make_db_node(...)

--- Search state (header line 1). search_active is true while the input is
--- being edited on line 1.
M.search_active = false
M.search_query = ""

--- Connections picker (first open): the browser buffer lists the redis
--- connections from connections.toml instead of the tree. <CR> on a row
--- makes it the context and lands on db 0 — never an automatic pick,
--- so the context is always an explicit user choice.
M.conn_picker = { active = false, nodes = {} }

--- Multi-select (poste-db db-browser pattern): <Tab> toggles a node into the
--- selection (restricted to nodes under the current db), <Esc> exits, D
--- batch-deletes the selection. Selected nodes render with a ✓ marker.
M.multi_select = { active = false, selected = {} }

--- Pending key reveal (browser/reveal.lua; resumed from render_tree).
M.reveal_state = nil

--- The browser's render function (tree render pipeline), installed by the
--- facade at load. Submodules render through THIS, not through
--- async.render_hook: the hook belongs to async's flush machinery, which
--- specs legitimately stub to nil — the browser must still render.
M.render = nil

--- The browser window, re-resolved when the cached handle went stale
--- (:q, split churn). nil when the buffer is not displayed.
--- @return number|nil
function M.window()
  if M.browser_win and vim.api.nvim_win_is_valid(M.browser_win) then
    return M.browser_win
  end
  if M.browser_buf and vim.api.nvim_buf_is_valid(M.browser_buf) then
    local win = vim.fn.bufwinid(M.browser_buf)
    if win ~= -1 then return win end
  end
  return nil
end

--- Forget the chosen context so the first-open picker path can be exercised
--- again (browser state persists across open/close; tests reset it).
function M.reset_scope()
  M.current_conn = nil
  M.current_db = 0
  M.current_db_node = nil
  M.search_active = false
  M.search_query = ""
  M.multi_select.active = false
  M.multi_select.selected = {}
  M.conn_picker.active = false
  M.conn_picker.nodes = {}
  M.reveal_state = nil
end

--- (Re)select a db: build its node, make it the display root, and scan_keys.
--- Rendering goes through M.render (installed by the facade).
--- @param db number
function M.select_db(db)
  if not M.current_conn then return end
  M.current_db = db
  M.current_db_node = tree.make_db_node({ db = db }, M.current_conn.name)
  tree.display_root = M.current_db_node
  M.search_query = ""
  -- the selection bound to the previous scope must not survive a switch:
  -- D after <Space> would otherwise batch-delete the OLD db's nodes
  M.multi_select.active = false
  M.multi_select.selected = {}
  scan.scan_keys(M.current_db_node, M.current_conn.url, M.current_conn.name)
  if M.render then M.render() end
end

return M
