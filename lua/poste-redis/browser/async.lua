--- Redis key browser async infrastructure (M2, P1-1/P1-2).
---
--- Pattern rebuilt from poste-db db_browser/async.lua, talking to the
--- persistent `redis-session` transport (session_conn.lua) so SELECT db state
--- is kept server-side and the connection is reused (P1-5).
---
--- This module owns what every async loader shares: the render hooks set by
--- browser/init.lua, the flush machinery that defers buffer work off
--- job-response callbacks, the tree view mode (flat/flatten/nested), TYPE
--- fetching, the search-by-subpath scan, and connection/db loading. The
--- cursor-driven SCAN loops + tree builders live in browser/scan.lua, which
--- depends on this module's pacing helpers — never the reverse.
---
--- Epoch guard: each fetch bumps node.epoch; callbacks from a superseded
--- fetch (user pressed r or navigated away) are dropped — red line #4.

local session_conn = require("poste-redis.session_conn")
local tree = require("poste-redis.browser.tree")
local config = require("poste-redis.config")
local connections = require("poste-redis.connections")

local M = {}
-- nested_view is OWNED by browser/tree.lua (flatten_tree reads it on every
-- render, and tree must not require this module back — that would be a
-- require cycle). This metatable forwards reads and writes of M.nested_view
-- to tree.nested_view, so every existing `async.nested_view` reference —
-- including the runtime set_view_mode writes — keeps working unchanged.
setmetatable(M, {
  __index = function(t, k)
    if k == "nested_view" then return tree.nested_view end
    return rawget(t, k)
  end,
  __newindex = function(t, k, v)
    if k == "nested_view" then tree.nested_view = v
    else rawset(t, k, v) end
  end,
})

--- Render hook set by browser/init.lua; called after every batch lands.
M.render_hook = nil

--- Incremental append hook set by browser/init.lua: append newly arrived
--- nodes under an already-rendered node without a full re-render.
--- @param node table
--- @param new_nodes table[]
--- @return boolean handled
M.append_hook = nil

--- Buffer work (renders + incremental appends) NEVER runs inside a
--- job-response callback: nvim 0.12 can permanently starve a job channel's
--- stdout reads when a buffer mutation overlaps responses arriving on
--- another chain (the browser froze mid-scan — timers kept firing, stdout
--- events never did). All buffer work is marked dirty here and flushed by a
--- one-shot uv timer once the session has nothing in flight. uv timers run
--- on the same loop that reads the pipes (and fire inside headless
--- vim.wait), so this is safe for tests too.
local render_dirty = false
local append_queue = {}  -- { { node = node, nodes = new_nodes }, ... }
local flush_timer = assert(vim.loop.new_timer())

local flush  -- forward declaration: arm_flush's timer callback captures it
local function arm_flush()
  -- Restart unconditionally: this debounces bursts of dirty marks into one
  -- flush 10ms after the last one (a quiet point), and never depends on a
  -- previous timer's pending state. schedule_wrap: the uv callback runs in a
  -- fast event context where nvim API calls (every render) are forbidden.
  flush_timer:start(10, 0, vim.schedule_wrap(function()
    pcall(flush)
  end))
end

local function schedule_flush()
  arm_flush()
end

function flush()
  if session_conn.in_flight() > 0 then
    -- still streaming: retry on the next timer tick
    arm_flush()
    return
  end
  local appends = append_queue
  append_queue = {}
  if render_dirty then
    -- a full render covers every queued append (the nodes are already in
    -- node.children; render_tree reads from there)
    render_dirty = false
    if M.render_hook then M.render_hook() end
    return
  end
  for _, a in ipairs(appends) do
    if not M.append_hook or not M.append_hook(a.node, a.nodes) then
      render_dirty = true  -- node not rendered: fall back to a full render
    end
  end
  if render_dirty and M.render_hook then
    render_dirty = false
    M.render_hook()
  end
end

--- Tree view mode of the key browser:
---   "flat"    → every key hangs directly under the db node (no folders)
---   "flatten" → 方案A: one folder per first `:`-segment, keys flat inside
---   "nested"  → 方案B: folders nest per `:`-segment (`a:b:c` → `a`/`b`/key)
--- tree_view/nested_view are the two booleans powering these:
---   tree_view=false            → "flat"
---   tree_view=true,!nested     → "flatten"
---   tree_view=true,nested=true → "nested"
-- Default mode from config (`browser_view_mode`). Applied once at module
-- load; the toggle commands (:PosteRedisBrowserView) change it at runtime.
-- M.nested_view is forwarded to tree.nested_view (single source of truth).
local _default_mode = config.config.browser_view_mode or "nested"
M.tree_view = _default_mode ~= "flat"
M.nested_view = _default_mode == "nested"

--- Set the tree view mode. Normalizes the two booleans so invalid
--- combinations (e.g. flat + nested) collapse to a legal state.
--- @param mode "flat" | "flatten" | "nested"
--- @return string the applied mode
function M.set_view_mode(mode)
  if mode == "flat" then
    M.tree_view = false
    M.nested_view = false
  elseif mode == "nested" then
    M.tree_view = true
    M.nested_view = true
  else
    M.tree_view = true
    M.nested_view = false
  end
  return M.view_mode()
end

--- Current view mode string.
--- @return "flat" | "flatten" | "nested"
function M.view_mode()
  if not M.tree_view then return "flat" end
  return M.nested_view and "nested" or "flatten"
end

--- Toggle between flatten (方案A) and nested (方案B), the two folder modes.
--- From "flat" it goes to nested (the richer layout).
--- @return string the applied mode
function M.toggle_view_mode()
  if M.view_mode() == "nested" then
    return M.set_view_mode("flatten")
  end
  return M.set_view_mode("nested")
end

--- Mark the tree dirty; browser/scan.lua and the loaders below call this
--- instead of rendering inline (see the flush note above).
function M.schedule_render()
  render_dirty = true
  schedule_flush()
end

--- Synchronous first-paint: the scan-start render runs before the first
--- request is dispatched (buffer is a single loading row — nothing can race
--- it). Keeps P1-1 (<300ms first screen) while every other buffer mutation
--- stays deferred to the quiet-point flush.
function M.render_now()
  if M.render_hook then M.render_hook() end
end

--- Session opts for browser scans: the redis-session process defaults to
--- --max-items 1000, which would truncate a SCAN COUNT 5000 reply to 1000
--- keys and silently drop the rest (cursor keeps advancing). Bump it so a
--- full SCAN page is never cut — this is why header discovery had to page at
--- 500. @param db number
--- @return table
function M.scan_session_opts(db)
  local max_items = math.max(config.config.header_scan_count or 5000, config.config.scan_count or 500) + 1000
  return { db = db, max_items = max_items }
end

--- Render a batch delta: queue the nodes for an incremental append under
--- `node` (flushed off the response path). Exported for browser/scan.lua.
function M.schedule_append(node, new_nodes)
  if not new_nodes or #new_nodes == 0 then return end
  append_queue[#append_queue + 1] = { node = node, nodes = new_nodes }
  schedule_flush()
end

--- Fetch the Redis type of key nodes via TYPE (persistent session, so the
--- requests pipeline over one connection). Sets node.meta.type as each
--- resolves and renders once the whole batch is typed — the type icon + color
--- flip together in one re-render. Skipped for nodes already typed.
--- TYPE reports only string/hash/list/set/zset/stream, so bitmap/hyperloglog/
--- geo still resolve as string/zset here (subtype probing is future work).
---
--- BOUNDED on purpose: at most `config.type_fetch_limit` keys are typed and
--- at most TYPE_WINDOW requests are in flight. Typing one request per key
--- flooded the shared redis-session process (a 100k-key group expand sent
--- 100k TYPEs; every later SCAN queued behind them and the browser looked
--- dead — no error, no refresh, nothing).
local TYPE_WINDOW = 64

--- @param key_nodes table[] key nodes (node_type == "key")
--- @param conn_url string
--- @param db number
--- @param guard_node table|nil node whose epoch guards the batch: when it
---   advances (r / new scan / search switch on the same db), the remaining
---   TYPE requests stop refilling instead of draining the shared session on a
---   tree that already reset — the batch never renders stale types either.
function M.fetch_types(key_nodes, conn_url, db, guard_node)
  local to_fetch = {}
  for _, n in ipairs(key_nodes or {}) do
    if n.node_type == "key" and not n.meta.type then
      to_fetch[#to_fetch + 1] = n
    end
  end
  local limit = math.min(#to_fetch, config.config.type_fetch_limit or 500)
  if limit <= 0 then return end
  local pending = limit
  local next_idx = 0
  local in_flight = 0
  local epoch = guard_node and guard_node.epoch

  local pump
  local function finish(n, ev)
    if guard_node and guard_node.epoch ~= epoch then
      -- superseded scan: stop refilling, render nothing (the new scan owns it)
      pending = 0
      return
    end
    if ev then
      local t = ev.value and ev.value.value
      if type(t) == "string" then n.meta.type = t end
    end
    pending = pending - 1
    if pending <= 0 then
      M.schedule_render()
    else
      pump()
    end
  end

  function pump()
    while next_idx < limit and in_flight < TYPE_WINDOW do
      next_idx = next_idx + 1
      local n = to_fetch[next_idx]
      in_flight = in_flight + 1
      session_conn.execute(conn_url, { "TYPE", n.meta.key }, {
        on_response = function(ev)
          in_flight = in_flight - 1
          finish(n, ev)
        end,
        on_error = function()
          in_flight = in_flight - 1
          finish(n, nil)
        end,
      }, nil, { db = db })
    end
  end

  pump()
end

--- Search-by-subpath: SCAN MATCH <subpath>* and render matching keys under a
--- dedicated hidden `<subpath>` results node. Same cursor/pacing/append
--- machinery as browser/scan.scan_group; the search bar in browser/init.lua
--- drives it on <leader>/ + <CR>.
---
--- The results node is NOT attached to db_node.children: while it exists,
--- init.render_tree makes it the hidden display root, so matched keys
--- REPLACE the rendered tree instead of appending a results subtree after
--- the unfiltered one. Reuses (or re-seeds) db_node._search_results so
--- re-searching replaces the previous results. Epoch is bumped on the db
--- node so a stale search (or a stale group scan on the same db) is dropped.
--- @param db_node table db node
--- @param conn_url string
--- @param conn_name string
--- @param subpath string e.g. "bench:a:b:c" (empty → clear)
function M.search(db_node, conn_url, conn_name, subpath)
  if subpath == nil or subpath == "" then
    M.search_clear(db_node)
    return
  end
  local db = db_node.meta.db
  db_node.epoch = (db_node.epoch or 0) + 1
  local epoch = db_node.epoch

  -- Result node: one per db, replaced on re-search. Never a child of the
  -- db node — init.render_tree swaps it in as the display root.
  local results = db_node._search_results
  if not results then
    results = tree.make_group_node(subpath, conn_name, db)
    results.is_search = true
    results.parent = db_node
    db_node._search_results = results
  else
    results.name = subpath
  end
  results.children = {}
  results.expanded = true
  results.loading = true
  results.error = nil
  M.render_now()

  local scan_count = config.config.scan_count or 500
  local all_keys = {}
  local built = 0
  local RENDER_EVERY_PAGES = 8
  local page = 0
  local match = subpath .. "*"

  local function next_page(cursor)
    if db_node.epoch ~= epoch then return end
    local cmd = { "SCAN", cursor, "COUNT", tostring(scan_count), "MATCH", match }
    session_conn.execute(conn_url, cmd, {
      on_response = function(ev)
        if db_node.epoch ~= epoch then return end
        local v = ev.value
        local keys = v and v.value or {}
        local new_cursor = (v and v.cursor) or "0"
        page = page + 1
        for _, k in ipairs(keys) do
          if type(k) == "string" then all_keys[#all_keys + 1] = k end
        end
        local final_page = new_cursor == "0"
        if page == 1 or page % RENDER_EVERY_PAGES == 0 or final_page then
          local new_nodes = {}
          for i = built + 1, #all_keys do
            local kn = tree.make_key_node(all_keys[i], conn_name, db)
            kn.parent = results
            table.insert(new_nodes, kn)
          end
          built = #all_keys
          for _, n in ipairs(new_nodes) do table.insert(results.children, n) end
          M.schedule_append(results, new_nodes)
        end
        if not final_page and tree.last_truncated > 0 then
          -- render cap hit: stop paging, the remaining matches would never show
          results.loading = false
          -- render BEFORE dispatching the TYPE batch (see scan_keys note)
          M.schedule_render()
          M.fetch_types(results.children, conn_url, db, db_node)
        elseif not final_page then
          next_page(new_cursor)
        else
          results.loading = false
          -- render BEFORE dispatching the TYPE batch (see scan_keys note)
          M.schedule_render()
          M.fetch_types(results.children, conn_url, db, db_node)
        end
      end,
      on_error = function(msg)
        if db_node.epoch ~= epoch then return end
        results.loading = false
        -- the results node IS the display root while searching: its error
        -- must land there or the status line never shows it
        results.error = msg
        M.schedule_render()
      end,
    }, nil, M.scan_session_opts(db))
  end

  next_page("0")
end

--- Drop a db node's search results; init.render_tree falls back to the db
--- node as display root, restoring the unfiltered tree. The db node's own
--- children were never touched by search(), so there is nothing to unsplice.
--- @param db_node table
function M.search_clear(db_node)
  if not db_node or not db_node._search_results then return end
  db_node.epoch = (db_node.epoch or 0) + 1
  db_node._search_results = nil
  M.schedule_render()
end

--- Load the connection list from connections.toml (redis dialect only).
--- @param cb fun(nodes: table[])
function M.load_connections(cb)
  connections.list_connections(function(entries)
    local nodes = {}
    for _, e in ipairs(entries or {}) do
      if e.dialect == "redis" then
        local url = e.url
        local node = tree.make_connection_node({ name = e.name, url = url, dialect = "redis" })
        table.insert(nodes, node)
      end
    end
    cb(nodes)
  end)
end

--- Fetch the list of databases for a connection. Redis defaults to 16 dbs;
--- we probe each with SELECT + DBSIZE via the session so only non-empty dbs
--- show up (cheap: 16 DBSIZE round-trips, all on one persistent connection).
--- @param node table connection node
--- @param conn_url string
--- @param cb fun(dbs: number[])
function M.fetch_dbs(node, conn_url, cb)
  node.epoch = (node.epoch or 0) + 1
  local epoch = node.epoch
  node.loading = true
  M.schedule_render()

  local dbs = {}
  local pending = 16
  local function done()
    if node.epoch ~= epoch then return end
    node.loading = false
    cb(dbs)
  end
  for db = 0, 15 do
    session_conn.execute(conn_url, { "DBSIZE" }, {
      on_response = function(ev)
        if node.epoch ~= epoch then return end
        local n = ev.value and ev.value.value
        if type(n) == "number" and n > 0 then
          dbs[#dbs + 1] = db
        end
        pending = pending - 1
        if pending <= 0 then done() end
      end,
      on_error = function()
        pending = pending - 1
        if pending <= 0 then done() end
      end,
    }, nil, M.scan_session_opts(db))
  end
end

M._test = {
  fetch_types = M.fetch_types,
  set_view_mode = M.set_view_mode,
  view_mode = M.view_mode,
  toggle_view_mode = M.toggle_view_mode,
}

return M
