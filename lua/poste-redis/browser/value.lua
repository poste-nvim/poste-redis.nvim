--- Redis key value viewer (M2, P1-3 baseline).
---
--- TYPE-first rendering: query the key's type, then fetch a bounded sample
--- per type and render it through the existing result panel (format.lua +
--- buffer.lua). Large strings are truncated by redis-exec's --max-bytes;
--- pagination (HSCAN for 10k-field hashes) lands with the full P1-3.
---
--- Runs on the persistent redis-session transport (session_conn) so the
--- SELECT db state is correct without touching the URL, and the connection
--- is reused across value views (P1-5). Async — the UI never blocks.

local session_conn = require("poste-redis.session_conn")
local buffer = require("poste-redis.buffer")
local format = require("poste-redis.format")
local redis_state = require("poste-redis.state")
local connections = require("poste-redis.connections")

local M = {}

--- Sample size per collection type.
local SAMPLE = 500

--- Build the fetch command for a key of the given type.
--- @param key string
--- @param type string|nil  redis TYPE result (string|hash|list|set|zset|stream|unknown)
--- @return string[]|nil command tokens
local function fetch_command(key, type)
  if type == "string" then return { "GET", key } end
  if type == "hash" then return { "HGETALL", key } end
  if type == "list" then return { "LRANGE", key, "0", tostring(SAMPLE - 1) } end
  if type == "set" then return { "SMEMBERS", key } end
  if type == "zset" then return { "ZRANGE", key, "0", tostring(SAMPLE - 1), "WITHSCORES" } end
  if type == "stream" then return { "XRANGE", key, "-", "+", "COUNT", tostring(SAMPLE) } end
  return { "GET", key }  -- unknown: try the raw string
end

--- Render a result event into the panel.
local function render(ev, key, type_name, conn_name, db)
  if not ev then
    vim.notify("Value fetch failed", vim.log.levels.ERROR, { title = redis_state.TITLE })
    return
  end
  local out = format.format_result(ev)
  out.meta.title = key .. "  [" .. tostring(type_name or "unknown") .. "]"
  out.meta.key = key
  out.meta.connection = conn_name
  out.meta.db = db
  buffer.render_snapshot(out.lines, out.meta)
end

--- View a key's value in the result panel.
--- @param node table browser key node
--- @param root_nodes table[] unused (API parity with browser/init.lua)
--- @param render_hook fun()|nil called after the panel opens (no-op)
function M.view(node, root_nodes, render_hook)
  local key = node.meta and node.meta.key
  local conn_name = node.meta and node.meta.connection
  if not key or not conn_name then
    vim.notify("Cannot resolve key", vim.log.levels.ERROR, { title = redis_state.TITLE })
    return
  end
  -- node.meta.url wins (browser builds nodes with resolved URLs); fall back
  -- to resolving the connection name from connections.toml.
  local url = node.meta and node.meta.url
  local err
  if not url then
    url, err = connections.resolve_redis_url(conn_name)
  end
  if not url then
    vim.notify("Connection '" .. conn_name .. "' not found: " .. tostring(err),
      vim.log.levels.ERROR, { title = redis_state.TITLE })
    return
  end
  local db = node.meta and node.meta.db or 0

  local known_type = node.meta and node.meta.type
  local function fetch_and_render(t)
    local cmd = fetch_command(key, t)
    if not cmd then
      vim.notify("No renderer for type " .. tostring(t), vim.log.levels.WARN,
        { title = redis_state.TITLE })
      return
    end
    session_conn.execute(url, cmd, {
      on_response = function(ev)
        render(ev, key, t, conn_name, db)
        if render_hook then render_hook() end
      end,
      on_error = function(msg)
        vim.notify("Value fetch failed: " .. tostring(msg), vim.log.levels.ERROR,
          { title = redis_state.TITLE })
      end,
    }, nil, { db = db })
  end

  if known_type then
    fetch_and_render(known_type)
    return
  end

  -- TYPE first, then fetch by type
  session_conn.execute(url, { "TYPE", key }, {
    on_response = function(ev)
      local t = ev.value and ev.value.value
      fetch_and_render(t)
    end,
    on_error = function(msg)
      vim.notify("TYPE failed: " .. tostring(msg), vim.log.levels.ERROR,
        { title = redis_state.TITLE })
    end,
  }, nil, { db = db })
end

M._test = {
  fetch_command = fetch_command,
  SAMPLE = SAMPLE,
}

return M
