--- Redis key browser async loading (M2, P1-1/P1-2).
---
--- Pattern rebuilt from poste-db db_browser/async.lua, talking to the
--- persistent `redis-session` transport (session_conn.lua) so SELECT db state
--- is kept server-side and the connection is reused (P1-5).
---
--- Loading is cursor-driven: SCAN cursor MATCH pattern COUNT scan_count loops
--- until cursor == "0", appending key nodes in batches. Renders are paced —
--- page 1 (first screen), then every RENDER_EVERY_PAGES-th page, then the
--- final page — so the UI never freezes and the first screen appears before
--- the full scan finishes (P1-1: first screen < 300ms). Rebuilding the whole
--- subtree + rewriting the buffer on EVERY page was O(n²) overall and made
--- keys look like they trickle in one by one.
---
--- Epoch guard: each fetch bumps node.epoch; callbacks from a superseded
--- fetch (user pressed r or navigated away) are dropped — red line #4.

local session_conn = require("poste-redis.session_conn")
local tree = require("poste-redis.browser.tree")
local config = require("poste-redis.config")
local connections = require("poste-redis.connections")

local M = {}

--- Render hook set by browser/init.lua; called after every batch lands.
M.render_hook = nil

--- Incremental append hook set by browser/init.lua: append newly arrived
--- nodes under an already-rendered node without a full re-render.
--- @param node table
--- @param new_nodes table[]
--- @return boolean handled
M.append_hook = nil

--- Tree view: group keys by the first `:`-segment. Flat view: keys hang
--- directly under the db node.
M.tree_view = true

--- SPLIT_NEST is the max group nesting depth; deeper segments stay flat
--- within the group (prevents pathological trees from `a:b:c:d:...` keys).
local SPLIT_NEST = 2

local function schedule_render()
  if M.render_hook then M.render_hook() end
end

--- Session opts for browser scans: the redis-session process defaults to
--- --max-items 1000, which would truncate a SCAN COUNT 5000 reply to 1000
--- keys and silently drop the rest (cursor keeps advancing). Bump it so a
--- full SCAN page is never cut — this is why header discovery had to page at
--- 500. @param db number
--- @return table
local function scan_session_opts(db)
  local max_items = math.max(config.config.header_scan_count or 5000, config.config.scan_count or 500) + 1000
  return { db = db, max_items = max_items }
end

--- Render a batch delta: append under `node` incrementally when possible,
--- otherwise fall back to a full render.
local function schedule_append(node, new_nodes)
  if not new_nodes or #new_nodes == 0 then return end
  if M.append_hook and M.append_hook(node, new_nodes) then return end
  schedule_render()
end

--- Reorder a node's children: flat keys first (arrival order), then group
--- nodes sorted by name — the stable layout for a db node.
local function sort_children(node)
  local flat, groups = {}, {}
  for _, ch in ipairs(node.children or {}) do
    if ch.node_type == "group" then groups[#groups + 1] = ch
    else flat[#flat + 1] = ch end
  end
  table.sort(groups, function(a, b) return a.name < b.name end)
  node.children = {}
  for _, f in ipairs(flat) do node.children[#node.children + 1] = f end
  for _, g in ipairs(groups) do node.children[#node.children + 1] = g end
end

--- Build (or extend) a db node's child list from a stream of SCAN keys,
--- lazily: one group header per distinct first `:`-segment + flat keys.
--- Groups are NOT loaded here — each loads on expand via scan_group
--- (SCAN MATCH <prefix>:*), so a 100k-key prefix costs nothing at db-expand.
--- Incremental: only keys from index `from` are new (idempotent groups).
--- @param node table db node
--- @param keys string[] all keys accumulated so far
--- @param conn_name string
--- @param db number
--- @param from number 1-based index of the first unseen key
--- @return table[] new_nodes created for this delta
local function build_group_headers(node, keys, conn_name, db, from)
  local new_nodes = {}
  if not M.tree_view then
    -- flat view: every key hangs directly under the db node
    for i = from, #keys do
      local kn = tree.make_key_node(keys[i], conn_name, db)
      kn.parent = node
      table.insert(node.children, kn)
      table.insert(new_nodes, kn)
    end
    return new_nodes
  end
  node._segs = node._segs or {}
  for i = from, #keys do
    local k = keys[i]
    local seg = k:match("^([^:]+):")
    if not seg then
      local kn = tree.make_key_node(k, conn_name, db)
      kn.parent = node
      table.insert(node.children, kn)
      table.insert(new_nodes, kn)
    else
      local g = node._segs[seg]
      if not g then
        g = tree.make_group_node(seg, conn_name, db)
        g.parent = node
        node._segs[seg] = g
        table.insert(node.children, g)
        table.insert(new_nodes, g)
      end
    end
  end
  return new_nodes
end

--- Full eager build of a db node's children from a flat key list, grouping by
--- `:` prefix when tree view is on. Used by toggle_view (rebuild) and tests.
--- @param node table db node
--- @param keys string[]
--- @param conn_name string
--- @param db number
local function build_children(node, keys, conn_name, db)
  node.children = {}
  if not M.tree_view or #keys == 0 then
    for _, k in ipairs(keys) do
      table.insert(node.children, tree.make_key_node(k, conn_name, db))
    end
    return
  end
  local buckets, order = {}, {}
  for _, k in ipairs(keys) do
    local seg = k:match("^([^:]+):") or ""
    if seg == "" then
      table.insert(node.children, tree.make_key_node(k, conn_name, db))
    else
      local b = buckets[seg]
      if not b then b = { keys = {} }; buckets[seg] = b; order[#order + 1] = seg end
      table.insert(b.keys, k)
    end
  end
  table.sort(order)
  for _, seg in ipairs(order) do
    local group = tree.make_group_node(seg, conn_name, db)
    group.children = {}
    for _, k in ipairs(buckets[seg].keys) do
      table.insert(group.children, tree.make_key_node(k, conn_name, db))
    end
    table.insert(node.children, group)
  end
end

--- SCAN-load a db node's group headers in batches (LAZY: groups are created
--- but not populated; each loads on expand via scan_group). This keeps db
--- expand O(distinct prefixes) instead of O(all keys) — a 100k-key db shows
--- its groups instantly. Batches append incrementally via append_hook.
---
--- Uses a LARGE COUNT (header_scan_count): finding distinct `:` prefixes
--- requires walking the whole keyspace, so paging at scan_count costs 200
--- round-trips on a 100k-key db; at 5000 it is ~21. Every page appends any
--- newly discovered prefixes immediately, and in tree view the loading
--- marker clears after the first page so the db node shows its groups fast.
--- @param node table db node
--- @param conn_url string
--- @param conn_name string
--- @param pattern string|nil  MATCH pattern (nil = no filter)
function M.scan_keys(node, conn_url, conn_name, pattern)
  local db = node.meta.db
  node.epoch = (node.epoch or 0) + 1
  local epoch = node.epoch
  node.loading = true
  node.children = {}
  node._segs = {}
  node.expanded = true
  schedule_render()

  local scan_count = config.config.header_scan_count or 5000
  local all_keys = {}
  local built = 0  -- keys already materialized into nodes
  local page = 0

  local function next_page(cursor)
    if node.epoch ~= epoch then return end
    local cmd = { "SCAN", cursor, "COUNT", tostring(scan_count) }
    if pattern and pattern ~= "" then
      cmd[#cmd + 1] = "MATCH"
      cmd[#cmd + 1] = pattern
    end
    session_conn.execute(conn_url, cmd, {
      on_response = function(ev)
        if node.epoch ~= epoch then return end
        -- redis_value_to_json renders SCAN's [cursor, keys[]] reply with the
        -- cursor surfaced in `value.cursor` and the keys in `value.value`
        -- (redis_executor.rs SCAN-family branch).
        local v = ev.value
        local keys = v and v.value or {}
        local new_cursor = (v and v.cursor) or "0"
        page = page + 1
        for _, k in ipairs(keys) do
          if type(k) == "string" then all_keys[#all_keys + 1] = k end
        end
        local final_page = new_cursor == "0"
        -- Every page may surface new prefixes: append them immediately.
        local new_nodes = build_group_headers(node, all_keys, conn_name, db, built + 1)
        built = #all_keys
        schedule_append(node, new_nodes)
        if not final_page then
          next_page(new_cursor)
        else
          sort_children(node)
          node.loading = false
          schedule_render()
        end
      end,
      on_error = function(msg)
        if node.epoch ~= epoch then return end
        node.loading = false
        node.error = msg
        schedule_render()
      end,
    }, nil, scan_session_opts(db))
  end

  next_page("0")
end

--- SCAN-load a group node's keys in batches (lazy, SCAN MATCH <prefix>:*).
--- Appends key nodes incrementally. `subpattern` narrows the match — this is
--- the same primitive a future search-by-subpath (e.g. bench:a:b:c) needs:
--- call scan_group(node, url, name, "a:b:c") → MATCH bench:a:b:c*.
--- @param node table group node
--- @param conn_url string
--- @param conn_name string
--- @param subpattern string|nil  extra path after the group prefix (search)
function M.scan_group(node, conn_url, conn_name, subpattern)
  local db = node.meta.db
  node.epoch = (node.epoch or 0) + 1
  local epoch = node.epoch
  node.loading = true
  node.children = {}
  node.expanded = true
  node.loaded = true
  schedule_render()

  local scan_count = config.config.scan_count or 500
  local all_keys = {}
  local built = 0
  local RENDER_EVERY_PAGES = 8
  local page = 0

  local prefix = node.meta.prefix or ""
  local match = prefix .. ":"
  if subpattern and subpattern ~= "" then
    match = match .. subpattern .. "*"
  else
    match = match .. "*"
  end

  local function next_page(cursor)
    if node.epoch ~= epoch then return end
    local cmd = { "SCAN", cursor, "COUNT", tostring(scan_count), "MATCH", match }
    session_conn.execute(conn_url, cmd, {
      on_response = function(ev)
        if node.epoch ~= epoch then return end
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
            kn.parent = node
            table.insert(new_nodes, kn)
          end
          built = #all_keys
          for _, n in ipairs(new_nodes) do table.insert(node.children, n) end
          schedule_append(node, new_nodes)
        end
        if not final_page then
          next_page(new_cursor)
        else
          node.loading = false
          schedule_render()
        end
      end,
      on_error = function(msg)
        if node.epoch ~= epoch then return end
        node.loading = false
        node.error = msg
        schedule_render()
      end,
    }, nil, scan_session_opts(db))
  end

  next_page("0")
end

--- Search-by-subpath: SCAN MATCH <subpath>* and render matching keys under a
--- dedicated hidden `<subpath>` results node. This is the same
--- cursor/pacing/append machinery as scan_group; the search bar in
--- browser/init.lua drives it on <leader>/ + <CR>.
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
  schedule_render()

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
          schedule_append(results, new_nodes)
        end
        if not final_page then
          next_page(new_cursor)
        else
          results.loading = false
          schedule_render()
        end
      end,
      on_error = function(msg)
        if db_node.epoch ~= epoch then return end
        results.loading = false
        db_node.error = msg
        schedule_render()
      end,
    }, nil, scan_session_opts(db))
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
  schedule_render()
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
  schedule_render()

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
    }, nil, scan_session_opts(db))
  end
end

M._test = {
  build_children = build_children,
  build_group_headers = build_group_headers,
  SPLIT_NEST = SPLIT_NEST,
}

return M
