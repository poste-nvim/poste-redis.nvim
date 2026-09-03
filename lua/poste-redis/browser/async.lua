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

--- SPLIT_NEST is the max folder nesting depth; keys that would land deeper
--- stay flat inside the deepest folder (prevents pathological trees from
--- `a:b:c:d:...` keys).
local SPLIT_NEST = 2

local function schedule_render()
  render_dirty = true
  schedule_flush()
end

--- Synchronous first-paint: the scan-start render runs before the first
--- request is dispatched (buffer is a single loading row — nothing can race
--- it). Keeps P1-1 (<300ms first screen) while every other buffer mutation
--- stays deferred to the quiet-point flush.
local function render_now()
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

--- Render a batch delta: queue the nodes for an incremental append under
--- `node` (flushed off the response path).
local function schedule_append(node, new_nodes)
  if not new_nodes or #new_nodes == 0 then return end
  append_queue[#append_queue + 1] = { node = node, nodes = new_nodes }
  schedule_flush()
end

--- Fetch the Redis type of key nodes via TYPE (persistent session, so the
--- requests pipeline over one connection). Sets node.meta.type as each
--- resolves and renders once the whole batch is typed — the type suffix +
--- icon flip together in one re-render. Skipped for nodes already typed.
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
function M.fetch_types(key_nodes, conn_url, db)
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

  local pump
  local function finish(n, ev)
    if ev then
      local t = ev.value and ev.value.value
      if type(t) == "string" then n.meta.type = t end
    end
    pending = pending - 1
    if pending <= 0 then
      schedule_render()
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
  if M.nested_view then
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

--- Recursively build a nested folder tree (方案B) from a flat key list: each
--- `:`-segment nest is one folder level, keys hang as leaves in the folder of
--- their longest proper prefix. A key equal to a folder prefix (e.g. `a:b`
--- when `a:b:c` also exists) stays a leaf alongside the subfolder. Folders
--- nest at most SPLIT_NEST deep; deeper segments stay flat inside the deepest
--- folder. Used by toggle_view (rebuild) and tests.
--- @param node table db/group node
--- @param keys string[] full keys whose prefix equals node.meta.prefix
--- @param conn_name string
--- @param db number
--- @param depth number current folder depth (db node → 0)
local function build_nested_children(node, keys, conn_name, db, depth)
  node.children = {}
  local prefix = node.meta.prefix or ""
  if depth >= SPLIT_NEST then
    for _, k in ipairs(keys) do
      table.insert(node.children, tree.make_key_node(k, conn_name, db))
    end
    return
  end
  local buckets, order, leaves = {}, {}, {}
  for _, k in ipairs(keys) do
    -- key minus the folder's own prefix ("a:b" under prefix "a" → "b")
    local rest = k
    if prefix ~= "" then rest = k:sub(#prefix + 2) end
    local seg = rest:match("^([^:]+):(.+)$")
    if seg then
      if not buckets[seg] then buckets[seg] = {}; order[#order + 1] = seg end
      table.insert(buckets[seg], k)
    else
      table.insert(leaves, k)
    end
  end
  table.sort(leaves)
  table.sort(order)
  for _, seg in ipairs(order) do
    local child_prefix = (prefix == "" and seg) or (prefix .. ":" .. seg)
    local group = tree.make_group_node(child_prefix, conn_name, db, seg)
    group.parent = node
    table.insert(node.children, group)
    build_nested_children(group, buckets[seg], conn_name, db, depth + 1)
  end
  for _, k in ipairs(leaves) do
    table.insert(node.children, tree.make_key_node(k, conn_name, db))
  end
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
  if M.nested_view then
    build_nested_children(node, keys, conn_name, db, 0)
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
  node.error = nil
  node.children = {}
  node._segs = {}
  node.expanded = true
  render_now()

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
          schedule_render()
          M.fetch_types(flat, conn_url, db)
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
          schedule_render()
          M.fetch_types(flat, conn_url, db)
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
  render_now()

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
          if M.nested_view then
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
          schedule_append(node, new_nodes)
        end
        -- Render cap hit: stop paging — rows beyond it would never render.
        if not final_page and tree.last_truncated > 0 then
          if M.nested_view then sort_children(node) end
          node.loading = false
          -- render BEFORE dispatching the TYPE batch (see scan_keys note)
          schedule_render()
          M.fetch_types(node.children, conn_url, db)
        elseif not final_page then
          next_page(new_cursor)
        else
          if M.nested_view then sort_children(node) end
          node.loading = false
          -- render BEFORE dispatching the TYPE batch (see scan_keys note)
          schedule_render()
          M.fetch_types(node.children, conn_url, db)
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
  results.error = nil
  render_now()

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
        if not final_page and tree.last_truncated > 0 then
          -- render cap hit: stop paging, the remaining matches would never show
          results.loading = false
          -- render BEFORE dispatching the TYPE batch (see scan_keys note)
          schedule_render()
          M.fetch_types(results.children, conn_url, db)
        elseif not final_page then
          next_page(new_cursor)
        else
          results.loading = false
          -- render BEFORE dispatching the TYPE batch (see scan_keys note)
          schedule_render()
          M.fetch_types(results.children, conn_url, db)
        end
      end,
      on_error = function(msg)
        if db_node.epoch ~= epoch then return end
        results.loading = false
        -- the results node IS the display root while searching: its error
        -- must land there or the status line never shows it
        results.error = msg
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
  build_nested_children = build_nested_children,
  build_group_headers = build_group_headers,
  build_group_nested = build_group_nested,
  fetch_types = M.fetch_types,
  SPLIT_NEST = SPLIT_NEST,
  set_view_mode = M.set_view_mode,
  view_mode = M.view_mode,
  toggle_view_mode = M.toggle_view_mode,
}

return M
