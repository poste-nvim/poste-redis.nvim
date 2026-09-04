--- Connections picker (first open): the browser window lists the
--- connections.toml entries instead of the tree until the user picks one.
--- Nothing is auto-picked — <CR> on a row makes it the context and lands on
--- db 0, swapping the list for the filter bar + separator + tree.
local tree = require("poste-redis.browser.tree")
local async = require("poste-redis.browser.async")
local state = require("poste-redis.browser.state")
local connections = require("poste-redis.connections")
local redis_state = require("poste-redis.state")

local M = {}

--- Sort the picker rows by name: list_connections walks the toml table with
--- pairs(), so the raw order flips between runs — the list must be stable.
local function sort_nodes(nodes)
  table.sort(nodes, function(a, b) return (a.name or "") < (b.name or "") end)
  return nodes
end

--- Header line 1 while the picker is up: a status cue instead of the search
--- bar (the bar takes the line back once a connection is chosen). With no
--- redis connections at all the line carries the reason.
--- @return string
function M.hint_text()
  if #state.conn_picker.nodes == 0 then
    return "No redis connections in connections.toml"
  end
  return "Select a connection  (<CR> connect)"
end

--- Park the cursor on the picker's starting row: the current context's
--- connection when one is already set (USE / :PosteRedisConnection), else the
--- first row. Positioning is a hint, not a choice — connecting takes <CR>.
local function focus_row()
  local win = state.window()
  if not win then return end
  local row = 1
  local ok, poste_state = pcall(require, "poste.state")
  local preferred = ok and poste_state.connection
  if preferred then
    for i, n in ipairs(state.conn_picker.nodes) do
      if n.name == preferred then row = i; break end
    end
  end
  vim.api.nvim_win_set_cursor(win, { tree.HEADER_LINES + row, 0 })
end

--- Show the connections list in place of the tree (first open, no context
--- chosen yet). Rendered in the browser window itself so the choice happens
--- where the tree will live.
function M.show()
  async.load_connections(function(nodes)
    state.conn_picker.active = true
    state.conn_picker.nodes = sort_nodes(nodes or {})
    if state.render then state.render() end
    if #state.conn_picker.nodes == 0 then
      vim.notify("No redis connections in connections.toml",
        vim.log.levels.WARN, { title = redis_state.TITLE })
      return
    end
    focus_row()
  end)
end

--- Make a connection the browser's context AND the global one (statusline
--- segment, result-panel stamping, file execution all follow), then land on
--- db 0 — select_db swaps the picker for the filter bar + separator + tree.
--- @param name string
--- @param url string
function M.connect(name, url)
  if not name or not url then return end
  state.current_conn = { name = name, url = url }
  state.conn_picker.active = false
  state.conn_picker.nodes = {}
  connections.apply_connection(name, url)
  state.select_db(0)
end

--- <CR> on a picker row: connect that connection. `node` may be nil (test
--- hook) to take the first listed connection.
--- @param node table|nil connection node
function M.choose(node)
  if not node then node = state.conn_picker.nodes[1] end
  if not node or node.node_type ~= "connection" then return end
  M.connect(node.name, node.meta and node.meta.url)
end

return M
