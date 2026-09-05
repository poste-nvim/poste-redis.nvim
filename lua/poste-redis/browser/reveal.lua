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
  -- no render here: the walk defers rendering and renders once at the end
end

--- Focus + finish. Kept separate from the walk so a deferred render can
--- re-enter here (render_tree → resume) without redoing the walk.
local function finish(node, key)
  -- no window yet (start() runs before the facade's M.open): stay pending —
  -- the render that M.open triggers re-enters resume and focuses then
  if not state.window() then return end
  if M.reveal_focus(node) then
    state.reveal_state = nil
    vim.notify("Revealed " .. key, vim.log.levels.INFO, { title = redis_state.TITLE })
  end
end

--- Advance the pending walk by one step. Called from render_tree (facade)
--- after every render, so scan-end renders naturally drive it.
---
--- Render discipline: descending ALREADY-LOADED folders is free (no render)
--- and every expansion only marks the walk dirty — ONE render at the end
--- materializes all of them, instead of a full render per path level. Lazy
--- folders scan first; their own flush renders resume the walk.
local function resume()
  local st = state.reveal_state
  if not st then return end

  -- the deferred render ran: park the cursor on the row we found
  if st.found then
    finish(st.found, st.key)
    return
  end

  local root = state.current_db_node
  if not root or not state.current_conn or root.loading then return end
  local node = st.node or root
  if node ~= root and node.loading then return end  -- a scan on the path streams

  if node.children == nil then
    -- lazy folder: scan; the flush's render resumes the walk
    scan.scan_group(node, state.current_conn.url, state.current_conn.name)
    node.expanded = true
    st.dirty = true
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
    st.found = child
    if st.dirty then
      -- one render materializes every expansion made during the walk;
      -- render_tree re-enters resume, which takes the finish branch
      if state.render then state.render() end
    else
      resume()  -- nothing changed: the row is already on screen
    end
    return
  end
  -- a folder on the path: open it (no render), then descend
  if not child.expanded or child.children == nil then
    expand(child)
    st.dirty = true
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

  -- Clear any active search BEFORE parking the reveal walk: clear() can
  -- trigger a render, and render_tree resumes a PENDING reveal against
  -- whatever tree is on screen — the OLD scope here, not the connection/db
  -- selected below. The stale walk either failed with "key not found" or
  -- parked the cursor on a row that select_db then re-built away.
  local searchbar = require("poste-redis.browser.searchbar")
  searchbar.clear()
  state.reveal_state = { key = key, node = nil }
  local db = opts.db or 0
  if not state.current_conn or state.current_conn.url ~= url or state.current_db ~= db then
    state.current_conn = { name = conn_name, url = url }
    state.conn_picker.active = false
    state.conn_picker.nodes = {}
    state.select_db(db)
  end
  resume()
  return true
end

return M
