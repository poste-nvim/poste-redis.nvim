--- Reveal: open the tree at a specific key (dataset `gd`,
--- :PosteRedisReveal, .redis `gd`). The walk is render-driven: folders on
--- the key's path expand lazily, and each scan-end render (render_tree →
--- resume) advances the walk until the key's row can be focused.
local tree = require("poste-redis.browser.tree")
local scan = require("poste-redis.browser.scan")
local state = require("poste-redis.browser.state")
local connections = require("poste-redis.connections")
local redis_state = require("poste-redis.state")

local M = {}

--- The child of `node` that leads to `key`: the key leaf itself, or the
--- group whose prefix the key lives under (lazy headers carry their
--- branch-point prefix, so folded spines match in one hop).
local function reveal_child(node, key)
  for _, ch in ipairs(node.children or {}) do
    if ch.node_type == "key" and ch.meta.key == key then return ch end
  end
  for _, ch in ipairs(node.children or {}) do
    if ch.node_type == "group" and ch.meta.prefix then
      local p = ch.meta.prefix .. ":"
      if key:sub(1, #p) == p then return ch end
    end
  end
  return nil
end

--- Park the browser cursor on a node's row.
--- @param node table
--- @return boolean focused
function M.reveal_focus(node)
  for i, n in ipairs(state.line_to_node) do
    if n == node then
      local win = state.window()
      if win then
        vim.api.nvim_win_set_cursor(win, { i + tree.HEADER_LINES, 0 })
      end
      return true
    end
  end
  return false
end

--- Mirror of the facade's expand_node for the walker: lazy folders scan
--- (their render resumes the walk), loaded ones just toggle and re-render.
local function expand(node)
  if node.node_type == "group" and not node.children then
    scan.scan_group(node, state.current_conn.url, state.current_conn.name)
    node.expanded = true
    return
  end
  node.expanded = true
  if state.render then state.render() end
end

--- Advance the pending walk by one step. Called from render_tree (facade)
--- after every render, so scan-end renders naturally drive it. Kept pending
--- whenever the key's row is not rendered yet.
local function resume()
  local st = state.reveal_state
  if not st then return end
  local root = state.current_db_node
  if not root or not state.current_conn or root.loading then return end
  local node = st.node or root
  if node ~= root and node.loading then return end  -- a scan on the path streams

  if node.children == nil then
    expand(node)  -- lazy folder: scan; walk resumes on render
    return
  end

  local child = reveal_child(node, st.key)
  if not child then
    state.reveal_state = nil
    vim.notify("Key not found in the browser tree: " .. st.key,
      vim.log.levels.INFO, { title = redis_state.TITLE })
    return
  end
  if child.node_type == "key" then
    -- focus only lands when the key's row is rendered; until the flush
    -- paints the expanded folder, keep the walk pending (render_tree retries)
    if M.reveal_focus(child) then
      state.reveal_state = nil
      vim.notify("Revealed " .. st.key, vim.log.levels.INFO, { title = redis_state.TITLE })
    end
    return
  end
  -- a folder on the path: open it, then descend (expand renders → resume)
  if not child.expanded or child.children == nil then
    expand(child)
  end
  st.node = child
  resume()
end
M.resume = resume

--- Begin a reveal: resolve the connection, set the pending walk, clear any
--- active search, and re-scope the browser when the request points somewhere
--- it is not already looking (browser-local scope only — the global context
--- is not clobbered). The caller shows the window (M.open) afterwards; the
--- walk continues across the renders that follow.
--- @param opts table { key, connection, url?, db? }
--- @return boolean accepted
function M.start(opts)
  opts = opts or {}
  local key = opts.key
  if not key or key == "" then return false end
  local conn_name = opts.connection
  local url = opts.url
  if not url and conn_name then
    local err
    url, err = connections.resolve(conn_name)
    if not url then
      vim.notify("Cannot resolve connection: " .. tostring(err or conn_name),
        vim.log.levels.ERROR, { title = redis_state.TITLE })
      return false
    end
  end
  if not url then
    vim.notify("No connection to reveal against", vim.log.levels.WARN,
      { title = redis_state.TITLE })
    return false
  end
  conn_name = conn_name or url

  state.reveal_state = { key = key, node = nil }
  local searchbar = require("poste-redis.browser.searchbar")
  searchbar.clear()
  local db = opts.db or 0
  if not state.current_conn or state.current_conn.url ~= url or state.current_db ~= db then
    state.current_conn = { name = conn_name, url = url }
    state.conn_picker.active = false
    state.conn_picker.nodes = {}
    state.select_db(db)
  else
    if state.render then state.render() end
  end
  resume()
  return true
end

return M
