--- Redis key-space scanning for the browser (M2, P1-1/P1-2): the
--- cursor-driven SCAN loops (db group headers, group keys) and the tree-node
--- builders that turn key lists into group/key nodes (flat / flatten /
--- nested views).
---
--- Render pacing (schedule_render / schedule_append / render_now), the
--- render hooks, the view-mode flags and fetch_types live in
--- browser/async.lua — scan depends on async, never the reverse (async keeps
--- search + connection/db loading).
---
--- Loading is cursor-driven: SCAN cursor MATCH pattern COUNT scan_count loops
--- until cursor == "0", appending key nodes in batches. Renders are paced —
--- page 1 (first screen), then every RENDER_EVERY_PAGES-th page, then the
--- final page — so the UI never freezes and the first screen appears before
--- the full scan finishes (P1-1: first screen < 300ms).
---
--- Epoch guard: each fetch bumps node.epoch; callbacks from a superseded
--- fetch (user pressed r or navigated away) are dropped — red line #4.

local async = require("poste-redis.browser.async")
local session_conn = require("poste-redis.session_conn")
local tree = require("poste-redis.browser.tree")
local config = require("poste-redis.config")

local M = {}

--- SPLIT_NEST is the max folder nesting depth; keys that would land deeper
--- stay flat inside the deepest folder (prevents pathological trees from
--- `a:b:c:d:...` keys).
local SPLIT_NEST = 2

--- Number of `:`-separated segments in a folder prefix ("" → 0, "a" → 1,
--- "a:b" → 2). Drives the nested-view nest cap.
local function seg_count(prefix)
  if not prefix or prefix == "" then return 0 end
  local n = 1
  for _ in prefix:gmatch(":") do n = n + 1 end
  return n
end

--- Reorder a node's children. Flat/flatten view: flat keys first (arrival
--- order), then group nodes sorted by name — the stable layout for a db
--- node. Nested view: subfolders first (sorted), then direct keys (sorted),
--- the filesystem reading order of 方案B.
local function sort_children(node)
  local flat, groups = {}, {}
  for _, ch in ipairs(node.children or {}) do
    if ch.node_type == "group" then groups[#groups + 1] = ch
    else flat[#flat + 1] = ch end
  end
  table.sort(groups, function(a, b) return a.name < b.name end)
  node.children = {}
  if async.nested_view then
    table.sort(flat, function(a, b) return a.name < b.name end)
    for _, g in ipairs(groups) do node.children[#node.children + 1] = g end
    for _, f in ipairs(flat) do node.children[#node.children + 1] = f end
  else
    for _, f in ipairs(flat) do node.children[#node.children + 1] = f end
    for _, g in ipairs(groups) do node.children[#node.children + 1] = g end
  end
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
  if not async.tree_view then
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
      -- Keys-under-prefix seen by this scan, stamped on the lazy header so
      -- the tree can show a child count before the group is expanded (exact
      -- in flatten view, subtree total in nested view — after expansion the
      -- rendered #children takes over).
      g._child_count = (g._child_count or 0) + 1
    end
  end
  return new_nodes
end

--- Key entries in a rebuild key list may be plain strings (scan/tests) or
--- `{ name = ..., type = ..., size = ... }` tables (toggle_view preserves the
--- typed metadata so icons/highlights survive a view rebuild).
--- @param e string|table
--- @return string name
local function key_entry_name(e)
  return type(e) == "table" and e.name or e or ""
end

--- @param e string|table
--- @return table|nil key-node opts ({ type, size }) for typed entries
local function key_entry_meta(e)
  if type(e) ~= "table" then return nil end
  local meta = {}
  if e.type then meta.type = e.type end
  if e.size then meta.size = e.size end
  if next(meta) then return meta end
  return nil
end

--- Recursively build a nested folder tree (方案B) from a flat key list: each
--- `:`-segment nest is one folder level, keys hang as leaves in the folder of
--- their longest proper prefix. A key equal to a folder prefix (e.g. `a:b`
--- when `a:b:c` also exists) stays a leaf alongside the subfolder. Folders
--- nest at most SPLIT_NEST deep; deeper segments stay flat inside the deepest
--- folder. Used by toggle_view (rebuild) and tests.
--- @param node table db/group node
--- @param keys (string|table)[] full keys whose prefix equals node.meta.prefix
--- @param conn_name string
--- @param db number
--- @param depth number current folder depth (db node → 0)
local function build_nested_children(node, keys, conn_name, db, depth)
  node.children = {}
  local prefix = node.meta.prefix or ""
  if depth >= SPLIT_NEST then
    for _, k in ipairs(keys) do
      table.insert(node.children, tree.make_key_node(
        key_entry_name(k), conn_name, db, key_entry_meta(k)))
    end
    return
  end
  local buckets, order, leaves = {}, {}, {}
  for _, k in ipairs(keys) do
    -- key minus the folder's own prefix ("a:b" under prefix "a" → "b")
    local name = key_entry_name(k)
    local rest = name
    if prefix ~= "" then rest = name:sub(#prefix + 2) end
    local seg = rest:match("^([^:]+):(.+)$")
    if seg then
      if not buckets[seg] then buckets[seg] = {}; order[#order + 1] = seg end
      table.insert(buckets[seg], k)
    else
      table.insert(leaves, k)
    end
  end
  table.sort(leaves, function(a, b) return key_entry_name(a) < key_entry_name(b) end)
  table.sort(order)
  for _, seg in ipairs(order) do
    local child_prefix = (prefix == "" and seg) or (prefix .. ":" .. seg)
    local group = tree.make_group_node(child_prefix, conn_name, db, seg)
    group.parent = node
    table.insert(node.children, group)
    build_nested_children(group, buckets[seg], conn_name, db, depth + 1)
  end
  for _, k in ipairs(leaves) do
    table.insert(node.children, tree.make_key_node(
      key_entry_name(k), conn_name, db, key_entry_meta(k)))
  end
end

--- Full eager build of a db node's children from a flat key list, grouping by
--- `:` prefix when tree view is on. Used by toggle_view (rebuild) and tests.
--- Keys are plain names or `{ name, type, size }` entries (type/size survive
--- the rebuild so icons + highlights don't reset to the string/default).
--- @param node table db node
--- @param keys (string|table)[]
--- @param conn_name string
--- @param db number
local function build_children(node, keys, conn_name, db)
  node.children = {}
  if not async.tree_view or #keys == 0 then
    for _, k in ipairs(keys) do
      table.insert(node.children, tree.make_key_node(
        key_entry_name(k), conn_name, db, key_entry_meta(k)))
    end
    return
  end
  if async.nested_view then
    build_nested_children(node, keys, conn_name, db, 0)
    return
  end
  local buckets, order = {}, {}
  for _, k in ipairs(keys) do
    local name = key_entry_name(k)
    local seg = name:match("^([^:]+):") or ""
    if seg == "" then
      table.insert(node.children, tree.make_key_node(
        key_entry_name(k), conn_name, db, key_entry_meta(k)))
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
      table.insert(group.children, tree.make_key_node(
        key_entry_name(k), conn_name, db, key_entry_meta(k)))
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
  node.error = nil
  node.children = {}
  node._segs = {}
  node.expanded = true
  async.render_now()

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
        async.schedule_append(node, new_nodes)
        -- Render cap hit: stop walking the keyspace — rows beyond it would
        -- never render, and each page's fallback render costs real time.
        if not final_page and tree.last_truncated > 0 then
          sort_children(node)
          node.loading = false
          local flat = {}
          for _, ch in ipairs(node.children or {}) do
            if ch.node_type == "key" then flat[#flat + 1] = ch end
          end
          -- render BEFORE dispatching the TYPE batch: the drain-end render
          -- must never run while responses are in flight (heavy buffer work
          -- that overlaps arriving channel events starves them — nvim 0.12)
          async.schedule_render()
          async.fetch_types(flat, conn_url, db)
        elseif not final_page then
          next_page(new_cursor)
        else
          sort_children(node)
          node.loading = false
          -- Only flat keys live on the db node (groups stay lazy); fetch
          -- their types so the tree shows real type icons immediately.
          local flat = {}
          for _, ch in ipairs(node.children or {}) do
            if ch.node_type == "key" then flat[#flat + 1] = ch end
          end
          -- render BEFORE dispatching the TYPE batch: the drain-end render
          -- must never run while responses are in flight (heavy buffer work
          -- that overlaps arriving channel events starves them — nvim 0.12)
          async.schedule_render()
          async.fetch_types(flat, conn_url, db)
        end
      end,
      on_error = function(msg)
        if node.epoch ~= epoch then return end
        node.loading = false
        node.error = msg
        async.schedule_render()
      end,
    }, nil, async.scan_session_opts(db))
  end

  next_page("0")
end

--- Incremental nested build for a group node from a stream of scanned keys:
--- keys whose remainder after the folder prefix has a further `:`-segment
--- create a lazy subfolder header (children=nil, loaded on expand); keys that
--- terminate at this folder become direct leaves. Mirrors the db-level
--- build_group_headers but under the folder's own prefix. Folds stay lazy, so
--- a deep prefix costs one header per distinct next segment per level.
--- @param node table group node
--- @param keys string[] full keys matching the folder's SCAN
--- @param conn_name string
--- @param db number
--- @param from number 1-based index of the first unseen key
--- @return table[] new_nodes
local function build_group_nested(node, keys, conn_name, db, from)
  local new_nodes = {}
  local prefix = node.meta.prefix or ""
  local depth = seg_count(prefix)
  node._nsegs = node._nsegs or {}
  for i = from, #keys do
    local k = keys[i]
    local rest = k
    if prefix ~= "" then rest = k:sub(#prefix + 2) end
    local seg = rest:match("^([^:]+)")
    local has_more = seg and rest:sub(#seg + 1) ~= ""
    if seg and has_more and depth < SPLIT_NEST then
      local sub_prefix = (prefix == "" and seg) or (prefix .. ":" .. seg)
      local g = node._nsegs[seg]
      if not g then
        g = tree.make_group_node(sub_prefix, conn_name, db, seg)
        g.parent = node
        node._nsegs[seg] = g
        table.insert(new_nodes, g)
      end
      -- Same stamp as build_group_headers: keys-under-prefix seen so far.
      g._child_count = (g._child_count or 0) + 1
    else
      local kn = tree.make_key_node(k, conn_name, db)
      kn.parent = node
      table.insert(new_nodes, kn)
    end
  end
  return new_nodes
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
  node.error = nil
  node.children = {}
  node._nsegs = {}
  node.expanded = true
  node.loaded = true
  async.render_now()

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
          if async.nested_view then
            new_nodes = build_group_nested(node, all_keys, conn_name, db, built + 1)
          else
            for i = built + 1, #all_keys do
              local kn = tree.make_key_node(all_keys[i], conn_name, db)
              kn.parent = node
              table.insert(new_nodes, kn)
            end
          end
          built = #all_keys
          for _, n in ipairs(new_nodes) do table.insert(node.children, n) end
          async.schedule_append(node, new_nodes)
        end
        -- Render cap hit: stop paging — rows beyond it would never render.
        if not final_page and tree.last_truncated > 0 then
          if async.nested_view then sort_children(node) end
          node.loading = false
          -- render BEFORE dispatching the TYPE batch (see scan_keys note)
          async.schedule_render()
          async.fetch_types(node.children, conn_url, db)
        elseif not final_page then
          next_page(new_cursor)
        else
          if async.nested_view then sort_children(node) end
          node.loading = false
          -- render BEFORE dispatching the TYPE batch (see scan_keys note)
          async.schedule_render()
          async.fetch_types(node.children, conn_url, db)
        end
      end,
      on_error = function(msg)
        if node.epoch ~= epoch then return end
        node.loading = false
        node.error = msg
        async.schedule_render()
      end,
    }, nil, async.scan_session_opts(db))
  end

  next_page("0")
end

M._test = {
  build_children = build_children,
  build_nested_children = build_nested_children,
  build_group_headers = build_group_headers,
  build_group_nested = build_group_nested,
  SPLIT_NEST = SPLIT_NEST,
}

return M
