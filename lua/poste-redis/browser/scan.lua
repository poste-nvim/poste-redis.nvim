--- Redis key-space scanning for the browser (M2, P1-1/P1-2): the
--- cursor-driven SCAN loops (db group headers, group keys) and the tree-node
--- builders that turn key lists into group/key nodes (flat / flatten /
--- nested views). In nested view the builders also pre-fold each lazy header
--- to its single-spine branch point (respine_headers/spine_fold) and stamp
--- the direct-children count its row will show after expansion.
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
--- `a:b:c:d:...` keys). Configurable via `browser_split_nest`. Single-spine
--- chains fold at render time (tree.lua), so a deeper cap costs no indentation.
local SPLIT_NEST = config.config.browser_split_nest or 6

--- Number of `:`-separated segments in a folder prefix ("" → 0, "a" → 1,
--- "a:b" → 2). Drives the nested-view nest cap.
local function seg_count(prefix)
  if not prefix or prefix == "" then return 0 end
  local n = 1
  for _ in prefix:gmatch(":") do n = n + 1 end
  return n
end

--- Single-spine fold of one lazy group header down to its branch point — the
--- lazy-scan counterpart of tree.lua's fold_walk. From `pfx`, bucket `keys`
--- (all full keys under `pfx:`) by their next `:` segment; while exactly one
--- segment remains, it has deeper keys (is a group) and no key terminates
--- exactly there, descend. Returns the folded prefix and the direct-children
--- count the header will render after expansion: distinct segments at the
--- stop level, +1 per segment that is both a terminal key and a group (that
--- renders as two rows) — or the flat key count once the SPLIT_NEST cap stops
--- splitting (deeper keys live as flat leaves inside). An empty rest (a
--- trailing-colon key equal to the spine prefix) buckets as a leaf sentinel.
--- @param pfx string absolute prefix of the header (never "")
--- @param keys string[] full keys under pfx
--- @return string folded_prefix, number direct_children
local function spine_fold(pfx, keys)
  local depth = seg_count(pfx)
  while depth < SPLIT_NEST do
    local kids, order = {}, {}
    for i = 1, #keys do
      local rest = keys[i]:sub(#pfx + 2)
      local seg, deeper = rest:match("^([^:]+):(.*)$")
      if not seg then
        -- no further colon: the key terminates here as a direct leaf (an
        -- empty rest — a trailing-colon key equal to pfx:":" — lands on the
        -- empty-string sentinel segment)
        seg = rest
        deeper = nil
      end
      local b = kids[seg]
      if not b then
        b = { deep = false, term = false, keys = {} }
        kids[seg] = b
        order[#order + 1] = seg
      end
      if deeper then b.deep = true else b.term = true end
      b.keys[#b.keys + 1] = keys[i]
    end
    if #order ~= 1 then
      local n = #order
      for i = 1, #order do
        local b = kids[order[i]]
        if b.term and b.deep then n = n + 1 end
      end
      return pfx, n
    end
    local b = kids[order[1]]
    -- a key terminating exactly at the sole segment makes that child a key
    -- leaf — the folder row stays over it (fold_walk stops the same way);
    -- two rows when a group of the same name also exists
    if b.term then return pfx, b.deep and 2 or 1 end
    pfx = pfx .. ":" .. order[1]
    keys = b.keys
    depth = depth + 1
  end
  return pfx, #keys
end

--- Re-stamp lazy group headers with their single-spine fold (nested view):
--- meta.prefix moves to the branch point — expansion SCANs from there, so one
--- expand lands on the branch instead of walking each intermediate level —
--- and _child_count becomes the direct-children count the row shows after
--- expansion. Headers already loaded/loading are frozen: their children match
--- the prefix they were scanned under. `full` re-stamps every header (last
--- build of a scan, before its final render); otherwise only `touched`
--- segments, so a newly created header carries its fold before its first
--- render. `headers`/`node._seg_keys` are the seg→header and seg→keys maps
--- the caller's builder maintains; header keys are the segment LOCAL to the
--- parent, so the absolute prefix is the owning node's prefix ("" on the db
--- node) joined with it.
--- @param node table db/group node owning the headers
--- @param headers table seg → lazy group node
--- @param full boolean re-stamp all headers, not just touched
--- @param touched table|nil seg → true (keys new since the last build)
local function respine_headers(node, headers, full, touched)
  if not async.nested_view then return end
  local seg_keys = node._seg_keys
  if not seg_keys then return end
  local base = node.meta.prefix or ""
  for seg, g in pairs(headers) do
    if full or (touched and touched[seg]) then
      if not (g.loaded or g.loading) then
        local bk = seg_keys[seg]
        if bk then
          local abs = (base == "" and seg) or (base .. ":" .. seg)
          local folded, n = spine_fold(abs, bk)
          g.meta.prefix = folded
          g.full_name = g.meta.connection .. "/" .. g.meta.db .. "/" .. folded
          g._child_count = n
        end
      end
    end
  end
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
--- @param full boolean|nil last build of the scan: re-fold every header
--- @return table[] new_nodes created for this delta
local function build_group_headers(node, keys, conn_name, db, from, full)
  local new_nodes = {}
  local nested = async.nested_view
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
  -- Nested view buckets each header's keys so respine_headers can pre-fold
  -- the lazy spine (prefix → branch point) and stamp direct-children counts;
  -- flatten view keeps the keys-under-prefix accumulation (there expansion
  -- loads the prefix's keys as one flat list, so the total IS the count).
  local seg_keys, touched
  if nested then
    node._seg_keys = node._seg_keys or {}
    seg_keys = node._seg_keys
    touched = {}
  end
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
      if nested then
        local bk = seg_keys[seg]
        if not bk then bk = {}; seg_keys[seg] = bk end
        bk[#bk + 1] = k
        touched[seg] = true
      else
        g._child_count = (g._child_count or 0) + 1
      end
    end
  end
  if touched then
    respine_headers(node, node._segs, full, touched)
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
  node._seg_keys = {}
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
        local new_nodes = build_group_headers(node, all_keys, conn_name, db, built + 1, final_page)
        built = #all_keys
        async.schedule_append(node, new_nodes)
        -- Render cap hit: stop walking the keyspace — rows beyond it would
        -- never render, and each page's fallback render costs real time.
        if not final_page and tree.last_truncated > 0 then
          -- last render of the scan: re-fold every header from the full
          -- keyspace before it, and drop the fold key buckets
          respine_headers(node, node._segs, true)
          sort_children(node)
          node.loading = false
          node._seg_keys = nil
          local flat = {}
          for _, ch in ipairs(node.children or {}) do
            if ch.node_type == "key" then flat[#flat + 1] = ch end
          end
          -- render BEFORE dispatching the TYPE batch: the drain-end render
          -- must never run while responses are in flight (heavy buffer work
          -- that overlaps arriving channel events starves them — nvim 0.12)
          async.schedule_render()
          async.fetch_types(flat, conn_url, db, node)
        elseif not final_page then
          next_page(new_cursor)
        else
          sort_children(node)
          node.loading = false
          node._seg_keys = nil
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
          async.fetch_types(flat, conn_url, db, node)
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
--- build_group_headers but under the folder's own prefix. Each subfolder is
--- pre-folded to its spine's branch point (respine_headers), so expanding it
--- lands there in one step. Folds stay lazy, so a deep prefix costs one
--- header per distinct next segment per level.
--- @param node table group node
--- @param keys string[] full keys matching the folder's SCAN
--- @param conn_name string
--- @param db number
--- @param from number 1-based index of the first unseen key
--- @param full boolean|nil last build of the scan: re-fold every header
--- @return table[] new_nodes
local function build_group_nested(node, keys, conn_name, db, from, full)
  local new_nodes = {}
  local prefix = node.meta.prefix or ""
  local depth = seg_count(prefix)
  node._nsegs = node._nsegs or {}
  node._seg_keys = node._seg_keys or {}
  local touched = {}
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
      local bk = node._seg_keys[seg]
      if not bk then bk = {}; node._seg_keys[seg] = bk end
      bk[#bk + 1] = k
      touched[seg] = true
    else
      local kn = tree.make_key_node(k, conn_name, db)
      kn.parent = node
      table.insert(new_nodes, kn)
    end
  end
  respine_headers(node, node._nsegs, full, touched)
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
  node._seg_keys = {}
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
            new_nodes = build_group_nested(node, all_keys, conn_name, db, built + 1, final_page)
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
          if async.nested_view then
            -- last render of the scan: re-fold every header before it
            respine_headers(node, node._nsegs, true)
            sort_children(node)
          end
          node.loading = false
          node._seg_keys = nil
          -- render BEFORE dispatching the TYPE batch (see scan_keys note)
          async.schedule_render()
          async.fetch_types(node.children, conn_url, db, node)
        elseif not final_page then
          next_page(new_cursor)
        else
          if async.nested_view then sort_children(node) end
          node.loading = false
          node._seg_keys = nil
          -- render BEFORE dispatching the TYPE batch (see scan_keys note)
          async.schedule_render()
          async.fetch_types(node.children, conn_url, db, node)
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
  spine_fold = spine_fold,
  SPLIT_NEST = SPLIT_NEST,
}

return M
