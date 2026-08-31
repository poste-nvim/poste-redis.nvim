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
  return connections.resolve_redis_url(name)
end

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = redis_state.TITLE })
end

--- Unified confirm gate for destructive browser actions.
--- @param question string
--- @return boolean
local function confirm(question)
  local choice = vim.fn.confirm(question, "&Yes\n&No", 2, "Warning")
  return choice == 1
end

--- Refresh the db node's key list after a mutation.
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
  local async = require("poste-redis.browser.async")
  db_node.children = nil
  async.scan_keys(db_node, url, db_node.meta.connection)
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
      reload(ctx.db_node, ctx.render)
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
          reload(db_node, ctx.render)
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
            reload(ctx.db_node, ctx.render)
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

M._test = {
  conn_url_for = conn_url_for,
  confirm = confirm,
}

return M
