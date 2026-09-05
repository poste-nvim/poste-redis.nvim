--- Redis key browser write actions (M2, P1-4: TTL / delete / rename).
---
--- All mutations go through the persistent redis-session transport
--- (session_conn) so SELECT db state is held server-side; every destructive
--- action hits a unified confirm gate before touching the server
--- (requirements §5 P1-4: 统一确认框; requirements §6 安全).

local session_conn = require("poste-redis.session_conn")
local redis_state = require("poste-redis.state")
local connections = require("poste-redis.connections")

local M = {}

--- Resolve the connection URL for a node (meta.url wins, else name lookup).
--- @param node table
--- @return string|nil url, string|nil err
local function conn_url_for(node)
  local url = node and node.meta and node.meta.url
  if url then return url, nil end
  local name = node and node.meta and node.meta.connection
  if not name then return nil, "node has no connection" end
  return connections.resolve(name)
end

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = redis_state.TITLE })
end

--- Record a mutation in the command history. `yank` carries an executable
--- form for batch deletes (a bare `DEL prefix:*` glob cannot run as-is).
local function record(command, opts)
  require("poste-redis.history").push(vim.tbl_extend("force", {
    command = command,
    kind = "write",
  }, opts or {}))
end

--- Executable redis-cli pipeline for every key matching a glob.
local function scan_pipeline(prefix)
  return ("redis-cli --scan --pattern '%s:*' | xargs redis-cli del"):format(prefix)
end

--- Unified confirm gate for destructive browser actions. Swappable in tests
--- via _test.set_confirm.
--- @param question string
--- @return boolean
local confirm_impl = function(question)
  local choice = vim.fn.confirm(question, "&Yes\n&No", 2, "Warning")
  return choice == 1
end
local function confirm(question)
  return confirm_impl(question)
end

--- Full db rescan of the db node's key list — the refresh fallback for when
--- a targeted in-place edit cannot be trusted (active search results).
--- @param db_node table
--- @param render fun()|nil
local function reload(db_node, render)
  if not db_node then
    if render then render() end
    return
  end
  local url, err = conn_url_for(db_node)
  if not url then
    notify("Cannot resolve connection: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  local scan = require("poste-redis.browser.scan")
  db_node.children = nil
  scan.scan_keys(db_node, url, db_node.meta.connection)
end

--- Refresh the tree after a mutation. Targeted by default: the caller mutates
--- the tree in place (detach) and only a render runs — a full db-wide rescan
--- for a one-key delete re-walked the whole keyspace. Falls back to a full
--- rescan while search results replace the tree: the mutation may live in the
--- results copy, and only scan_keys rebuilds both sides consistently.
--- @param db_node table|nil
--- @param render fun()|nil
--- @param mutate fun()|nil  in-place tree edit (nil = render-only refresh)
--- @return boolean targeted  true when the in-place path ran
local function refresh_tree(db_node, render, mutate)
  -- mutations invalidate completion's key-prefix cache
  pcall(function() require("poste-redis.completion.data").clear_key_cache() end)
  local bst = require("poste-redis.browser.state")
  if bst.current_db_node and bst.current_db_node._search_results then
    reload(db_node, render)
    return false
  end
  if mutate then mutate() end
  if render then render() end
  return true
end

--- Remove a node from its parent's child list (and the parent's seg maps).
--- Prunes a LOADED group left empty, walking up, so `user:` disappears from
--- the tree when its last key is deleted — without rescanning the db.
--- @param node table
local function detach_node(node)
  local parent = node.parent
  if not parent or not parent.children then return end
  local kept = {}
  for _, ch in ipairs(parent.children) do
    if ch ~= node then kept[#kept + 1] = ch end
  end
  parent.children = kept
  for _, field in ipairs({ "_segs", "_nsegs" }) do
    local segs = parent[field]
    if segs then
      for seg, g in pairs(segs) do
        if g == node then segs[seg] = nil end
      end
    end
  end
  -- the db display root never goes away; only loaded groups collapse
  if parent.node_type == "group" and parent.loaded and #parent.children == 0 then
    detach_node(parent)
  end
end

----------------------------------------------------------------------
-- Delete
----------------------------------------------------------------------

--- Delete a single key with confirmation.
--- @param node table key node
--- @param ctx table { db_node, render }
function M.delete_key(node, ctx)
  ctx = ctx or {}
  local key = node.meta and node.meta.key
  local url, err = conn_url_for(node)
  if not key or not url then
    notify("Cannot resolve key/connection: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  if not confirm(("Delete key  %s  ?"):format(key)) then
    notify("Deletion cancelled")
    return
  end
  session_conn.execute(url, { "DEL", key }, {
    on_response = function(ev)
      local n = ev.value and ev.value.value
      notify(("Deleted %s (%s key(s))"):format(key, tostring(n or 0)))
      record("DEL " .. key, { connection = node.meta and node.meta.connection, db = node.meta and node.meta.db })
      refresh_tree(ctx.db_node, ctx.render, function() detach_node(node) end)
    end,
    on_error = function(msg)
      notify("DEL failed: " .. tostring(msg), vim.log.levels.ERROR)
    end,
  }, nil, { db = node.meta and node.meta.db })
end

--- Delete all keys under a prefix (a group node) with count estimation and
--- a second confirmation (P1-4: 按前缀删除前显示匹配数量预估并二次确认).
--- @param node table group node
--- @param ctx table { db_node, render }
function M.delete_prefix(node, ctx)
  ctx = ctx or {}
  local prefix = node.meta and node.meta.prefix
  local db_node = ctx.db_node or node.parent
  local url, err = conn_url_for(node)
  if not prefix or not url then
    notify("Cannot resolve prefix/connection: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  local db = node.meta and node.meta.db
  -- Estimate matching keys with SCAN MATCH prefix:*
  session_conn.execute(url, { "SCAN", "0", "MATCH", prefix .. ":*", "COUNT", "1000" }, {
    on_response = function(ev)
      -- SCAN reply: {type, value: keys[], cursor} (redis_executor SCAN branch)
      local keys = ev.value and ev.value.value or {}
      local key_list = {}
      for _, k in ipairs(keys) do
        if type(k) == "string" then key_list[#key_list + 1] = k end
      end
      local question = ("Delete %d key(s) matching  %s:*  ?"):format(#key_list, prefix)
      if not confirm(question) then
        notify("Deletion cancelled")
        return
      end
      -- delete one by one via DEL (no Lua scripting in M2 scope)
      local function del_next(i)
        if i > #key_list then
          notify(("Deleted %d key(s) under %s:*"):format(#key_list, prefix))
          -- one history line for the whole batch, not one per key
          record(("DEL %s:*"):format(prefix), {
            connection = node.meta and node.meta.connection,
            db = db,
            count = #key_list,
            yank = scan_pipeline(prefix),
          })
          -- the prefix's whole subtree is gone: drop its row, no rescan
          refresh_tree(db_node, ctx.render, function() detach_node(node) end)
          return
        end
        session_conn.execute(url, { "DEL", key_list[i] }, {
          on_response = function() del_next(i + 1) end,
          on_error = function(msg)
            notify(("DEL %s failed: %s"):format(key_list[i], tostring(msg)), vim.log.levels.ERROR)
            del_next(i + 1)
          end,
        }, nil, { db = db })
      end
      if #key_list > 0 then del_next(1) end
    end,
    on_error = function(msg)
      notify("SCAN estimate failed: " .. tostring(msg), vim.log.levels.ERROR)
    end,
  }, nil, { db = db })
end

--- Delete a group/db node and every key under it (full SCAN cursor loop,
--- y/n confirm before the batch). The node is removed from the tree after.
--- @param node table group node (or any node with a meta.prefix)
--- @param ctx table { db_node, render }
function M.delete_node(node, ctx)
  ctx = ctx or {}
  local prefix = node.meta and node.meta.prefix
  local db_node = ctx.db_node or node.parent
  local url, err = conn_url_for(node)
  if not prefix or not url then
    notify("Cannot resolve prefix/connection: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  local db = node.meta and node.meta.db
  local key_list = {}

  local function delete_batch()
    local question
    if #key_list == 0 then
      question = ("Delete node  %s  (no keys under it)?"):format(prefix)
    else
      question = ("Delete node  %s  and all %d key(s) under it?"):format(prefix, #key_list)
    end
    if not confirm(question) then
      notify("Deletion cancelled")
      return
    end
    local function del_next(i)
      if i > #key_list then
        notify(("Deleted node %s (%d key(s))"):format(prefix, #key_list))
        record(("DEL %s:*"):format(prefix), {
          connection = node.meta and node.meta.connection,
          db = db,
          count = #key_list,
          yank = scan_pipeline(prefix),
        })
        -- drop the node from its parent (detach_node prunes emptied groups)
        refresh_tree(db_node, ctx.render, function() detach_node(node) end)
        return
      end
      session_conn.execute(url, { "DEL", key_list[i] }, {
        on_response = function() del_next(i + 1) end,
        on_error = function(msg)
          notify(("DEL %s failed: %s"):format(key_list[i], tostring(msg)), vim.log.levels.ERROR)
          del_next(i + 1)
        end,
      }, nil, { db = db })
    end
    del_next(1)
  end

  local function next_page(cursor)
    session_conn.execute(url, { "SCAN", cursor, "COUNT", "5000", "MATCH", prefix .. ":*" }, {
      on_response = function(ev)
        for _, k in ipairs(ev.value and ev.value.value or {}) do
          if type(k) == "string" then key_list[#key_list + 1] = k end
        end
        local cursor2 = (ev.value and ev.value.cursor) or "0"
        if cursor2 == "0" then
          delete_batch()
        else
          next_page(cursor2)
        end
      end,
      on_error = function(msg)
        notify("SCAN failed: " .. tostring(msg), vim.log.levels.ERROR)
      end,
    }, nil, { db = db })
  end

  next_page("0")
end

--- Batch-delete several selected nodes (multi-select) with one confirm.
--- Key nodes DEL directly; group nodes SCAN their prefix first.
--- @param nodes table[] selected nodes
--- @param ctx table { db_node, render }
--- @param on_done fun()|nil  called after the batch (e.g. exit multi-select)
function M.delete_nodes(nodes, ctx)
  ctx = ctx or {}
  if not nodes or #nodes == 0 then return end
  local db_node = ctx.db_node
  local url, err = conn_url_for(nodes[1])
  if not url then
    notify("Cannot resolve connection: " .. tostring(err), vim.log.levels.ERROR)
    return
  end

  -- Resolve each node's keys: keys contribute themselves, groups scan.
  local jobs = {}  -- { node = node, keys = { ... } }
  for _, node in ipairs(nodes) do
    if node.node_type == "key" then
      jobs[#jobs + 1] = { node = node, keys = { node.meta.key } }
    else
      jobs[#jobs + 1] = { node = node, keys = {} }
    end
  end
  local pending_scans = 0
  -- Batch delete helper. Defined BEFORE the group-scan loop: scan callbacks
  -- (which may fire synchronously in tests) call confirm_and_run, so it must
  -- be bound before any group's scan_next dispatches.
  local function confirm_and_run()
    if pending_scans > 0 then return end
    local total = 0
    for _, job in ipairs(jobs) do total = total + #job.keys end
    if not confirm(("Delete %d selected node(s) and their %d key(s)?"):format(#jobs, total)) then
      notify("Deletion cancelled")
      return
    end
    local flat = {}
    for _, job in ipairs(jobs) do
      for _, k in ipairs(job.keys) do flat[#flat + 1] = k end
    end
    local function del_next(i)
      if i > #flat then
        notify(("Deleted %d key(s) across %d node(s)"):format(#flat, #jobs))
        -- one aggregated history line: literal keys + prefix globs; the yank
        -- form splits globs into redis-cli scan pipelines (a bare glob DEL
        -- cannot be pasted into redis-cli)
        local patterns, yank_lines, lit = {}, {}, {}
        for _, job in ipairs(jobs) do
          if job.node.node_type == "key" then
            patterns[#patterns + 1] = job.node.meta.key
            lit[#lit + 1] = job.node.meta.key
          else
            if #lit > 0 then yank_lines[#yank_lines + 1] = "DEL " .. table.concat(lit, " "); lit = {} end
            local pfx = job.node.meta.prefix or ""
            patterns[#patterns + 1] = pfx .. ":*"
            yank_lines[#yank_lines + 1] = scan_pipeline(pfx)
          end
        end
        if #lit > 0 then yank_lines[#yank_lines + 1] = "DEL " .. table.concat(lit, " ") end
        record("DEL " .. table.concat(patterns, " "), {
          connection = nodes[1].meta and nodes[1].meta.connection,
          db = nodes[1].meta and nodes[1].meta.db,
          count = #flat,
          yank = table.concat(yank_lines, "\n"),
        })
        for _, job in ipairs(jobs) do
          detach_node(job.node)
        end
        refresh_tree(db_node, ctx.render, nil)
        if ctx.on_done then ctx.on_done() end
        return
      end
      session_conn.execute(url, { "DEL", flat[i] }, {
        on_response = function() del_next(i + 1) end,
        on_error = function(msg)
          notify(("DEL %s failed: %s"):format(flat[i], tostring(msg)), vim.log.levels.ERROR)
          del_next(i + 1)
        end,
      }, nil, { db = nodes[1].meta and nodes[1].meta.db })
    end
    del_next(1)
  end

  for _, job in ipairs(jobs) do
    if job.node.node_type == "group" then
      pending_scans = pending_scans + 1
      local match = (job.node.meta.prefix or "") .. ":*"
      local db = job.node.meta and job.node.meta.db
      local function scan_next(cursor)
        session_conn.execute(url, { "SCAN", cursor, "COUNT", "5000", "MATCH", match }, {
          on_response = function(ev)
            for _, k in ipairs(ev.value and ev.value.value or {}) do
              if type(k) == "string" then job.keys[#job.keys + 1] = k end
            end
            local cursor2 = (ev.value and ev.value.cursor) or "0"
            if cursor2 == "0" then
              pending_scans = pending_scans - 1
              if pending_scans == 0 then confirm_and_run() end
            else
              scan_next(cursor2)
            end
          end,
          on_error = function(msg)
            notify("SCAN failed: " .. tostring(msg), vim.log.levels.ERROR)
            pending_scans = pending_scans - 1
            if pending_scans == 0 then confirm_and_run() end
          end,
        }, nil, { db = db })
      end
      scan_next("0")
    end
  end

  if pending_scans == 0 then confirm_and_run() end
end

----------------------------------------------------------------------
-- TTL
----------------------------------------------------------------------

--- Show / edit the TTL of a key. `t` prompts for seconds:
---   positive → EXPIRE; 0 → DEL-equivalent expiry; -1 → PERSIST.
--- @param node table key node
--- @param ctx table { db_node, render }
function M.set_ttl(node, ctx)
  ctx = ctx or {}
  local key = node.meta and node.meta.key
  local url, err = conn_url_for(node)
  if not key or not url then
    notify("Cannot resolve key/connection: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  local db = node.meta and node.meta.db

  session_conn.execute(url, { "TTL", key }, {
    on_response = function(ev)
      local ttl = ev.value and ev.value.value
      local ttl_str = ttl == nil and "?" or tostring(ttl)
      vim.ui.input({
        prompt = ("TTL for %s (seconds, -1 = PERSIST, current: %s): "):format(key, ttl_str),
        default = "-1",
      }, function(input)
        if not input or input == "" then return end
        local secs = tonumber(input)
        if secs == nil then
          notify("Invalid TTL: " .. input, vim.log.levels.ERROR)
          return
        end
        local cmd
        if secs < 0 then
          cmd = { "PERSIST", key }
        else
          cmd = { "EXPIRE", key, tostring(secs) }
        end
        session_conn.execute(url, cmd, {
          on_response = function()
            notify(("TTL set on %s (%s)"):format(key, input))
            record(table.concat(cmd, " "), {
              connection = node.meta and node.meta.connection, db = db,
            })
            -- EXPIRE/PERSIST never change the keyspace: the tree stays valid,
            -- no rescan (a full db scan here froze the browser on every `t`)
          end,
          on_error = function(msg)
            notify("TTL update failed: " .. tostring(msg), vim.log.levels.ERROR)
          end,
        }, nil, { db = db })
      end)
    end,
    on_error = function(msg)
      notify("TTL query failed: " .. tostring(msg), vim.log.levels.ERROR)
    end,
  }, nil, { db = db })
end

----------------------------------------------------------------------
-- Rename
----------------------------------------------------------------------

--- Rename a key with RENAME conflict detection (P1-4).
--- @param node table key node
--- @param ctx table { db_node, render }
function M.rename_key(node, ctx)
  ctx = ctx or {}
  local key = node.meta and node.meta.key
  local url, err = conn_url_for(node)
  if not key or not url then
    notify("Cannot resolve key/connection: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  local db = node.meta and node.meta.db

  vim.ui.input({ prompt = ("Rename %s to: "):format(key), default = key }, function(new_key)
    if not new_key or new_key == "" or new_key == key then return end
    -- Conflict detection: EXISTS on the target (RENAME would overwrite).
    session_conn.execute(url, { "EXISTS", new_key }, {
      on_response = function(ev)
        local exists = ev.value and ev.value.value
        if exists and exists > 0 then
          if not confirm(("%s exists — RENAME overwrites it. Continue?"):format(new_key)) then
            notify("Rename cancelled")
            return
          end
        end
        session_conn.execute(url, { "RENAME", key, new_key }, {
          on_response = function()
            notify(("Renamed %s → %s"):format(key, new_key))
            record(("RENAME %s %s"):format(key, new_key), {
              connection = node.meta and node.meta.connection, db = db,
            })
            reload(ctx.db_node, ctx.render)
          end,
          on_error = function(msg)
            notify("RENAME failed: " .. tostring(msg), vim.log.levels.ERROR)
          end,
        }, nil, { db = db })
      end,
      on_error = function(msg)
        notify("EXISTS failed: " .. tostring(msg), vim.log.levels.ERROR)
      end,
    }, nil, { db = db })
  end)
end

----------------------------------------------------------------------
-- Yank
----------------------------------------------------------------------

--- Copy the key name to the system clipboard.
--- @param node table key node
function M.yank_key(node)
  local key = node.meta and node.meta.key
  if not key then
    notify("No key to yank", vim.log.levels.WARN)
    return
  end
  vim.fn.setreg("+", key)
  notify(("Yanked: %s"):format(key))
end

M._test = {
  conn_url_for = conn_url_for,
  confirm = confirm,
  set_confirm = function(fn) confirm_impl = fn end,
}

return M
