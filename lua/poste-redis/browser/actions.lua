--- Redis key browser write actions (M2, P1-4: TTL / delete / rename).
---
--- All mutations go through the persistent redis-session transport
--- (session_conn) so SELECT db state is held server-side; every destructive
--- action hits a unified confirm gate before touching the server
--- (requirements §5 P1-4: 统一确认框; requirements §6 安全).

local session_conn = require("poste-redis.session_conn")
local redis_state = require("poste-redis.state")
local connections = require("poste-redis.connections")
local util = require("poste-redis.util")

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

--- Record a mutation in the command history. `cmd` is the token list, rendered
--- by util.render_command so keys containing whitespace record quoted (a key
--- `a b` reads back as `DEL "a b"`, not the ambiguous `DEL a b`). `yank`
--- carries an executable form for batch deletes (a bare `DEL prefix:*` glob
--- cannot run as-is).
local function record(cmd, opts)
  require("poste-redis.history").push(vim.tbl_extend("force", {
    command = util.render_command(cmd),
    kind = "write",
  }, opts or {}))
end

--- Executable redis-cli pipeline for every key matching a glob. The prefix
--- is glob-escaped so it matches only itself (a key `a*b:1` under folder
--- `a*b` must not drag `aXb:1` into the delete).
local function scan_pipeline(prefix)
  return ("redis-cli --scan --pattern '%s:*' | xargs redis-cli del")
    :format(util.glob_escape(prefix))
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

--- Refuse a write whose target name exists only as a rendering. A key whose
--- name is not valid UTF-8 cannot cross the JSON transport as bytes, so the
--- tree holds its hex preview instead: `(binary) N bytes hex: …` (SCAN hands
--- key names through the value path). The text addresses nothing — DEL and
--- EXPIRE answer 0 for it, which this module reports as success, and RENAME
--- answers "no such key". Identical rule to grid_edit's name guard; see
--- util.is_hex_display for what counts as a rendering.
--- @param name string|nil
--- @return string|nil reason
local function display_only_name(name)
  if not util.is_hex_display(name) then return nil end
  return ("'%s' is how a non-UTF-8 key name renders — it is not the name on "
    .. "the server, so nothing can be changed under it from the browser. "
    .. "Send the command yourself, with the bytes escaped"):format(tostring(name))
end

--- Notify-and-refuse form of display_only_name, for the single-node actions.
--- @param name string|nil
--- @return boolean refused
local function refuse_display_only(name)
  local why = display_only_name(name)
  if not why then return false end
  notify(why, vim.log.levels.WARN)
  return true
end

--- Drop the selected nodes whose name is only a rendering (batch actions):
--- key nodes by their key, group nodes by the prefix their DEL-batch would
--- SCAN. Reports how many went missing so a short count is never silent.
--- @param nodes table[]
--- @return table[] kept, number skipped
local function addressable(nodes)
  local kept, skipped = {}, 0
  for _, node in ipairs(nodes) do
    local name = node.meta and (node.node_type == "key" and node.meta.key
      or node.meta.prefix)
    if name and display_only_name(name) then
      skipped = skipped + 1
    else
      kept[#kept + 1] = node
    end
  end
  if skipped > 0 then
    notify(("%d selected node(s) are skipped: their names are only a rendering "
      .. "of non-UTF-8 bytes, not the name on the server"):format(skipped),
      vim.log.levels.WARN)
  end
  return kept, skipped
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
  if refuse_display_only(key) then return end
  if not confirm(("Delete key  %s  ?"):format(key)) then
    notify("Deletion cancelled")
    return
  end
  session_conn.execute(url, { "DEL", key }, {
    on_response = function(ev)
      local n = ev.value and ev.value.value
      notify(("Deleted %s (%s key(s))"):format(key, tostring(n or 0)))
      record({ "DEL", key }, { connection = node.meta and node.meta.connection, db = node.meta and node.meta.db })
      refresh_tree(ctx.db_node, ctx.render, function() detach_node(node) end)
    end,
    on_error = function(msg)
      notify("DEL failed: " .. tostring(msg), vim.log.levels.ERROR)
    end,
  }, nil, { db = node.meta and node.meta.db, owner = "browser" })
end

--- Shared engine for delete_prefix (`D`) and delete_node (`d` on a group):
--- full SCAN cursor loop collecting the prefix's keys, ONE confirm showing
--- the real count (a single estimate page undercounted multi-page prefixes
--- and the delete silently missed the rest), serial DELs, one aggregated
--- history line with an executable yank pipeline, then the tree detach.
--- @param node table group node
--- @param ctx table { db_node, render }
--- @param opts table { count_per_page = number, question = fun(count, prefix) }
local function delete_prefix_keys(node, ctx, opts)
  ctx = ctx or {}
  local prefix = node.meta and node.meta.prefix
  local db_node = ctx.db_node or node.parent
  local url, err = conn_url_for(node)
  if not prefix or not url then
    notify("Cannot resolve prefix/connection: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  if refuse_display_only(prefix) then return end
  local db = node.meta and node.meta.db
  -- SCAN pages may repeat a key (at-least-once) and this list is both the
  -- confirm count and the DEL batch, so it goes through the dedup collector
  local key_list, seen = {}, {}

  local function confirm_and_delete()
    if not confirm(opts.question(#key_list, prefix)) then
      notify("Deletion cancelled")
      return
    end
    -- delete one by one via DEL (no Lua scripting in M2 scope)
    local function del_next(i)
      if i > #key_list then
        notify(("Deleted %d key(s) under %s:*"):format(#key_list, prefix))
        -- one history line for the whole batch, not one per key
        record({ "DEL", prefix .. ":*" }, {
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
      }, nil, { db = db, owner = "browser" })
    end
    del_next(1)
  end

  local function next_page(cursor)
    session_conn.execute(url, {
      "SCAN", cursor, "COUNT", tostring(opts.count_per_page),
      "MATCH", util.glob_escape(prefix) .. ":*",
    }, {
      on_response = function(ev)
        -- SCAN reply: {type, value: keys[], cursor} (redis_executor SCAN branch)
        util.append_new(key_list, seen, ev.value and ev.value.value or {})
        local cursor2 = (ev.value and ev.value.cursor) or "0"
        if cursor2 == "0" then
          confirm_and_delete()
        else
          next_page(cursor2)
        end
      end,
      on_error = function(msg)
        notify("SCAN failed: " .. tostring(msg), vim.log.levels.ERROR)
      end,
    }, nil, { db = db, owner = "browser" })
  end

  next_page("0")
end

--- Delete all keys under a prefix (a group node) with count estimation and
--- a second confirmation (P1-4: 按前缀删除前显示匹配数量预估并二次确认).
--- @param node table group node
--- @param ctx table { db_node, render }
function M.delete_prefix(node, ctx)
  delete_prefix_keys(node, ctx, {
    count_per_page = 1000,
    question = function(count, prefix)
      return ("Delete %d key(s) matching  %s:*  ?"):format(count, prefix)
    end,
  })
end

--- Delete a group node and every key under it (full SCAN cursor loop, y/n
--- confirm before the batch). The node is removed from the tree after.
--- @param node table group node (or any node with a meta.prefix)
--- @param ctx table { db_node, render }
function M.delete_node(node, ctx)
  delete_prefix_keys(node, ctx, {
    count_per_page = 5000,
    question = function(count, prefix)
      if count == 0 then
        return ("Delete node  %s  (no keys under it)?"):format(prefix)
      end
      return ("Delete node  %s  and all %d key(s) under it?"):format(prefix, count)
    end,
  })
end

--- Batch-delete several selected nodes (multi-select) with one confirm.
--- Key nodes DEL directly; group nodes SCAN their prefix first. A selection
--- whose nodes are all display-only is dropped before the confirm (see
--- addressable), like a cancelled batch: multi-select stays where it was.
--- @param nodes table[] selected nodes
--- @param ctx table { db_node, render, on_done }  on_done runs after the batch
function M.delete_nodes(nodes, ctx)
  ctx = ctx or {}
  if not nodes or #nodes == 0 then return end
  nodes = addressable(nodes)
  if #nodes == 0 then return end
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
      for _, k in ipairs(job.keys) do
        -- carry the OWNING node's db: DELs must run against the same db the
        -- SCAN collected the key from (multi-select is currently single-db,
        -- but nothing here should silently depend on that)
        flat[#flat + 1] = { key = k, db = job.node.meta and job.node.meta.db }
      end
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
        local cmd_toks = { "DEL" }
        vim.list_extend(cmd_toks, patterns)
        record(cmd_toks, {
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
      session_conn.execute(url, { "DEL", flat[i].key }, {
        on_response = function() del_next(i + 1) end,
        on_error = function(msg)
          notify(("DEL %s failed: %s"):format(flat[i].key, tostring(msg)), vim.log.levels.ERROR)
          del_next(i + 1)
        end,
      }, nil, { db = flat[i].db, owner = "browser" })
    end
    del_next(1)
  end

  for _, job in ipairs(jobs) do
    if job.node.node_type == "group" then
      pending_scans = pending_scans + 1
      local match = util.glob_escape(job.node.meta.prefix or "") .. ":*"
      local db = job.node.meta and job.node.meta.db
      local seen = {}  -- one dedup set per job: its own key list
      local function scan_next(cursor)
        session_conn.execute(url, { "SCAN", cursor, "COUNT", "5000", "MATCH", match }, {
          on_response = function(ev)
            util.append_new(job.keys, seen, ev.value and ev.value.value or {})
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
        }, nil, { db = db, owner = "browser" })
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
--- Takes the shared action ctx ({ db_node, render }) for signature parity —
--- EXPIRE never touches the tree, so neither field is read.
--- @param node table key node
--- @param ctx table|nil unused
function M.set_ttl(node, _ctx)
  local key = node.meta and node.meta.key
  local url, err = conn_url_for(node)
  if not key or not url then
    notify("Cannot resolve key/connection: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  if refuse_display_only(key) then return end
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
            record(cmd, {
              connection = node.meta and node.meta.connection, db = db,
            })
            -- EXPIRE/PERSIST never change the keyspace: the tree stays valid,
            -- no rescan (a full db scan here froze the browser on every `t`)
          end,
          on_error = function(msg)
            notify("TTL update failed: " .. tostring(msg), vim.log.levels.ERROR)
          end,
        }, nil, { db = db, owner = "browser" })
      end)
    end,
    on_error = function(msg)
      notify("TTL query failed: " .. tostring(msg), vim.log.levels.ERROR)
    end,
  }, nil, { db = db, owner = "browser" })
end

--- Batch TTL over a multi-select (`t` with an active selection): ONE seconds
--- prompt, then EXPIRE (or PERSIST for negatives) on every selected key node.
--- Group nodes in the selection are skipped — a folder has no single TTL.
--- @param nodes table[] selected nodes
--- @param ctx table { db_node, render, on_done }
function M.set_ttl_nodes(nodes, ctx)
  ctx = ctx or {}
  local keys = {}
  for _, node in ipairs(nodes or {}) do
    if node.node_type == "key" and node.meta and node.meta.key then
      keys[#keys + 1] = node
    end
  end
  keys = addressable(keys)
  if #keys == 0 then
    notify("No key nodes selected", vim.log.levels.WARN)
    return
  end
  local url, err = conn_url_for(keys[1])
  if not url then
    notify("Cannot resolve connection: " .. tostring(err), vim.log.levels.ERROR)
    return
  end

  vim.ui.input({
    prompt = ("TTL for %d key(s) (seconds, -1 = PERSIST): "):format(#keys),
  }, function(input)
    if not input or input == "" then return end
    local secs = tonumber(input)
    if secs == nil then
      notify("Invalid TTL: " .. input, vim.log.levels.ERROR)
      return
    end
    local failed = 0
    local function apply(i)
      if i > #keys then
        if failed == 0 then
          notify(("TTL set on %d key(s) (%s)"):format(#keys, input))
        else
          notify(("TTL set on %d/%d key(s); %d failed"):format(#keys - failed, #keys, failed),
            vim.log.levels.WARN)
        end
        -- one aggregated history line (a bare multi-key EXPIRE is not a real
        -- command — the yank form carries one redis-cli line per key)
        local toks, yank_lines = { "EXPIRE" }, {}
        for _, node in ipairs(keys) do
          toks[#toks + 1] = node.meta.key
          yank_lines[#yank_lines + 1] = ("redis-cli EXPIRE '%s' %s"):format(node.meta.key, tostring(secs))
        end
        record(toks, {
          connection = keys[1].meta and keys[1].meta.connection,
          db = keys[1].meta and keys[1].meta.db,
          count = #keys,
          yank = table.concat(yank_lines, "\n"),
        })
        if ctx.on_done then ctx.on_done() end
        return
      end
      local node = keys[i]
      local node_url = conn_url_for(node) or url
      local node_db = node.meta and node.meta.db
      local cmd = secs < 0 and { "PERSIST", node.meta.key }
        or { "EXPIRE", node.meta.key, tostring(secs) }
      session_conn.execute(node_url, cmd, {
        on_response = function() apply(i + 1) end,
        on_error = function(msg)
          failed = failed + 1
          notify(("TTL %s failed: %s"):format(node.meta.key, tostring(msg)), vim.log.levels.ERROR)
          apply(i + 1)
        end,
      }, nil, { db = node_db, owner = "browser" })
    end
    apply(1)
  end)
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
  if refuse_display_only(key) then return end
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
            record({ "RENAME", key, new_key }, {
              connection = node.meta and node.meta.connection, db = db,
            })
            reload(ctx.db_node, ctx.render)
          end,
          on_error = function(msg)
            notify("RENAME failed: " .. tostring(msg), vim.log.levels.ERROR)
          end,
        }, nil, { db = db, owner = "browser" })
      end,
      on_error = function(msg)
        notify("EXISTS failed: " .. tostring(msg), vim.log.levels.ERROR)
      end,
    }, nil, { db = db, owner = "browser" })
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
