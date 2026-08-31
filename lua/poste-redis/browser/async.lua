--- Redis key browser async loading (M2, P1-1/P1-2).
---
--- Pattern rebuilt from poste-db db_browser/async.lua, talking to the
--- persistent `redis-session` transport (session_conn.lua) so SELECT db state
--- is kept server-side and the connection is reused (P1-5).
---
--- Loading is cursor-driven: SCAN cursor MATCH pattern COUNT scan_count loops
--- until cursor == "0", appending key nodes in batches. Each batch re-renders
--- so the UI never freezes and the first screen appears before the full scan
--- finishes (P1-1: first screen < 300ms, UI never blocks on 100k-key dbs).
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

--- Tree view: group keys by the first `:`-segment. Flat view: keys hang
--- directly under the db node.
M.tree_view = true

--- SPLIT_NEST is the max group nesting depth; deeper segments stay flat
--- within the group (prevents pathological trees from `a:b:c:d:...` keys).
local SPLIT_NEST = 2

local function schedule_render()
  if M.render_hook then M.render_hook() end
end

--- Build (or update) the child list of a db node from a flat key list,
--- grouping by `:` prefix when tree view is on.
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

  -- Tree view: bucket by first `:` segment.
  local buckets = {}  -- segment -> { keys = {} }
  local order = {}
  for _, k in ipairs(keys) do
    local seg = k:match("^([^:]+):") or ""
    if seg == "" then
      -- key without a `:` stays flat under the db node
      table.insert(node.children, tree.make_key_node(k, conn_name, db))
    else
      local b = buckets[seg]
      if not b then
        b = { keys = {} }
        buckets[seg] = b
        order[#order + 1] = seg
      end
      table.insert(b.keys, k)
    end
  end
  table.sort(order)
  for _, seg in ipairs(order) do
    local b = buckets[seg]
    local group = tree.make_group_node(seg, conn_name, db)
    group.children = {}
    for _, k in ipairs(b.keys) do
      table.insert(group.children, tree.make_key_node(k, conn_name, db))
    end
    table.insert(node.children, group)
  end
end

--- Fetch the TYPE + size for a key (best-effort; failures degrade to
--- type=unknown silently — the browser must never block on metadata).
--- @param conn_url string
--- @param db number
--- @param key string
--- @param cb fun(type: string|nil, size: string|nil)
local function fetch_key_meta(conn_url, db, key, cb)
  local done = false
  local function finish(t, s)
    if not done then done = true; cb(t, s) end
  end
  session_conn.execute(conn_url, { "TYPE", key }, {
    on_response = function(ev)
      local t = ev.value and ev.value.value or nil
      local size_cmd
      if t == "string" then size_cmd = "STRLEN"
      elseif t == "hash" then size_cmd = "HLEN"
      elseif t == "list" then size_cmd = "LLEN"
      elseif t == "set" then size_cmd = "SCARD"
      elseif t == "zset" then size_cmd = "ZCARD"
      elseif t == "stream" then size_cmd = "XLEN"
      end
      if size_cmd then
        session_conn.execute(conn_url, { size_cmd, key }, {
          on_response = function(ev2)
            local n = ev2.value and ev2.value.value
            finish(t, n ~= nil and tostring(n) or nil)
          end,
          on_error = function() finish(t, nil) end,
        })
      else
        finish(t, nil)
      end
    end,
    on_error = function() finish(nil, nil) end,
  }, nil, { db = db })
end

--- SCAN-load a db node's keys in batches. Batches are appended to
--- node.children via build_children so the tree stays stable across scans.
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
  schedule_render()

  local scan_count = config.config.scan_count or 500
  local all_keys = {}

  local function next_page(cursor)
    if node.epoch ~= epoch then return end  -- superseded fetch
    local cmd = { "SCAN", cursor, "COUNT", tostring(scan_count) }
    if pattern and pattern ~= "" then
      cmd[#cmd + 1] = "MATCH"
      cmd[#cmd + 1] = pattern
    end
    session_conn.execute(conn_url, cmd, {
      on_response = function(ev)
        if node.epoch ~= epoch then return end
        -- redis_value_to_json renders SCAN's [cursor, keys[]] reply as
        -- {type:"list", value:[cursor, [keys...]]}
        local v = ev.value
        local arr = v and v.value
        local new_cursor = "0"
        local keys = {}
        if type(arr) == "table" then
          new_cursor = tostring(arr[1] or "0")
          local klist = arr[2]
          if type(klist) == "table" then
            for _, k in ipairs(klist) do
              if type(k) == "string" then keys[#keys + 1] = k end
            end
          end
        end
        for _, k in ipairs(keys) do
          all_keys[#all_keys + 1] = k
        end
        build_children(node, all_keys, conn_name, db)
        schedule_render()
        if new_cursor ~= "0" then
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
    }, nil, { db = db })
  end

  next_page("0")
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
    }, nil, { db = db })
  end
end

M._test = {
  build_children = build_children,
  SPLIT_NEST = SPLIT_NEST,
}

return M
