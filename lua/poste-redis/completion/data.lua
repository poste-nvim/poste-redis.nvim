--- Redis completion — data + cache layer.
---
--- Sources:
---   - COMMANDS: built-in Redis command table (~190, RESP common set) — the
---     same vocabulary the regex syntax highlights (requirements §3.4)
---   - connection names: from connections.toml redis sections
---   - key prefix candidates: SCAN MATCH `<prefix>*` via the persistent
---     session transport (P2-4 "光标 key 前缀候选"), cached per (url, prefix)
---
--- All transport goes through session_conn so SELECT db state is respected
--- and the connection is reused (P1-5).
local connections = require("poste-redis.connections")
local session_conn = require("poste-redis.session_conn")
local config = require("poste-redis.config")

local M = {}

---------------------------------------------------------------------------
-- Redis command table
---------------------------------------------------------------------------

--- Built-in Redis commands offered at the command-name position. This is a
--- display/hint table only — the parser stays "dumb" (D6) and the binary
--- does the actual dispatch.
local COMMANDS = {
  -- Keys
  "COPY", "DEL", "DUMP", "EXISTS", "EXPIRE", "EXPIREAT", "KEYS", "MIGRATE",
  "MOVE", "OBJECT", "PERSIST", "PEXPIRE", "PEXPIREAT", "PTTL", "RANDOMKEY",
  "RENAME", "RENAMENX", "RESTORE", "SCAN", "SORT", "TOUCH", "TTL", "TYPE",
  "UNLINK", "WAIT",
  -- Strings
  "APPEND", "BITCOUNT", "BITFIELD", "BITOP", "BITPOS", "DECR", "DECRBY",
  "GET", "GETBIT", "GETDEL", "GETEX", "GETRANGE", "GETSET", "INCR", "INCRBY",
  "INCRBYFLOAT", "MGET", "MSET", "MSETNX", "PSETEX", "SET", "SETBIT",
  "SETEX", "SETNX", "SETRANGE", "STRLEN", "SUBSTR",
  -- Hashes
  "HDEL", "HEXISTS", "HGET", "HGETALL", "HINCRBY", "HINCRBYFLOAT", "HKEYS",
  "HLEN", "HMGET", "HMSET", "HRANDFIELD", "HSCAN", "HSET", "HSETNX",
  "HSTRLEN", "HVALS",
  -- Lists
  "BLMOVE", "BLPOP", "BRPOP", "BRPOPLPUSH", "LINDEX", "LINSERT", "LLEN",
  "LMOVE", "LPOP", "LPOS", "LPUSH", "LPUSHX", "LRANGE", "LREM", "LSET",
  "LTRIM", "RPOP", "RPOPLPUSH", "RPUSH", "RPUSHX",
  -- Sets
  "SADD", "SCARD", "SDIFF", "SDIFFSTORE", "SINTER", "SINTERCARD",
  "SINTERSTORE", "SISMEMBER", "SMEMBERS", "SMISMEMBER", "SMOVE", "SPOP",
  "SRANDMEMBER", "SREM", "SSCAN", "SUNION", "SUNIONSTORE",
  -- Sorted sets
  "BZPOPMAX", "BZPOPMIN", "ZADD", "ZCARD", "ZCOUNT", "ZDIFF", "ZDIFFSTORE",
  "ZINCRBY", "ZINTER", "ZINTERCARD", "ZINTERSTORE", "ZLEXCOUNT", "ZMPOP",
  "ZMSCORE", "ZPOPMAX", "ZPOPMIN", "ZRANDMEMBER", "ZRANGE", "ZRANGEBYLEX",
  "ZRANGEBYSCORE", "ZRANGESTORE", "ZRANK", "ZREM", "ZREMRANGEBYLEX",
  "ZREMRANGEBYRANK", "ZREMRANGEBYSCORE", "ZREVRANGE", "ZREVRANGEBYLEX",
  "ZREVRANGEBYSCORE", "ZREVRANK", "ZSCAN", "ZSCORE", "ZUNION", "ZUNIONSTORE",
  -- Streams
  "XACK", "XADD", "XAUTOCLAIM", "XCLAIM", "XDEL", "XGROUP", "XINFO",
  "XLEN", "XPENDING", "XRANGE", "XREAD", "XREADGROUP", "XREVRANGE",
  "XSETID", "XTRIM",
  -- HyperLogLog
  "PFADD", "PFCOUNT", "PFMERGE",
  -- Geo
  "GEOADD", "GEODIST", "GEOHASH", "GEOPOS", "GEORADIUS", "GEORADIUSBYMEMBER",
  "GEOSEARCH", "GEOSEARCHSTORE",
  -- Server
  "ACL", "BGREWRITEAOF", "BGSAVE", "CLIENT", "COMMAND", "CONFIG", "DBSIZE",
  "DEBUG", "FLUSHALL", "FLUSHDB", "INFO", "LASTSAVE", "LATENCY", "LOLWUT",
  "MEMORY", "MODULE", "MONITOR", "REPLICAOF", "ROLE", "SAVE", "SHUTDOWN",
  "SLAVEOF", "SLOWLOG", "SWAPDB", "TIME",
  -- Connection
  "AUTH", "ECHO", "HELLO", "PING", "QUIT", "SELECT", "RESET",
  -- Transactions
  "DISCARD", "EXEC", "MULTI", "UNWATCH", "WATCH",
  -- Scripting
  "EVAL", "EVALSHA", "EVALSHA_RO", "EVAL_RO", "FCALL", "FCALL_RO",
  "FUNCTION", "SCRIPT",
  -- Pub/Sub
  "PSUBSCRIBE", "PUBLISH", "PUBSUB", "PUNSUBSCRIBE", "SPUBLISH",
  "SSUBSCRIBE", "SUBSCRIBE", "SUNSUBSCRIBE", "UNSUBSCRIBE",
  -- Cluster
  "ASKING", "CLUSTER", "READONLY", "READWRITE",
}

M.COMMANDS = COMMANDS

---------------------------------------------------------------------------
-- Connection names
---------------------------------------------------------------------------

local conn_names_cache = nil

--- Load redis connection names from connections.toml (cached, async cb).
--- @param callback fun(names: string[])
function M.ensure_conn_names(callback)
  if conn_names_cache then callback(conn_names_cache); return end
  vim.schedule(function()
    local names = connections.redis_connection_names()
    table.sort(names)
    conn_names_cache = names
    callback(names)
  end)
end

---------------------------------------------------------------------------
-- Key prefix candidates (SCAN MATCH prefix*)
---------------------------------------------------------------------------

local key_cache = {}          -- key -> string[] candidates
local key_fetching = {}       -- fetch key -> true
local key_callbacks = {}      -- fetch key -> cb[]
local key_fetch_gen = {}      -- fetch key -> generation (stale-response guard)
local fetch_gen_counter = 0   -- monotonic; clear_key_cache invalidates via wipe

--- Run queued callbacks for a fetch key with the given candidates.
local function flush_key(fkey, candidates)
  key_fetching[fkey] = nil
  local cbs = key_callbacks[fkey] or {}
  key_callbacks[fkey] = nil
  for _, cb in ipairs(cbs) do cb(candidates) end
end

--- Queue a callback for an in-flight fetch key.
local function queue_key(fkey, cb)
  key_callbacks[fkey] = key_callbacks[fkey] or {}
  table.insert(key_callbacks[fkey], cb)
end

--- Fetch keys matching `<prefix>*` (single SCAN page, async). Results are
--- cached per (conn_url, prefix) so repeated keystrokes don't re-SCAN.
--- Empty prefix is skipped — completing `GET <space>` with the whole keyspace
--- is a full-db scan (the browser already covers browsing; here we only hint).
---
--- Performance on large keyspaces (task 2026-09-03): SCAN MATCH is O(buckets)
--- not O(keyspace) per call and COUNT bounds each page, so one round-trip
--- stays ~ms even on 100k+ keys; caching per prefix means typing longer
--- prefixes never re-scans. Completion is prefix-gated (empty prefix → no
--- candidates) and capped at completion_max_keys so menus stay small.
--- @param conn_url string
--- @param prefix string
--- @param db number|nil
--- @param callback fun(candidates: string[])
function M.ensure_key_candidates(conn_url, prefix, db, callback)
  prefix = prefix or ""
  if prefix == "" or not conn_url then
    callback({})
    return
  end

  local key = conn_url .. "|" .. tostring(db or 0) .. "|" .. prefix
  if key_cache[key] then callback(key_cache[key]); return end

  local fkey = "keys:" .. key
  if key_fetching[fkey] then queue_key(fkey, callback); return end
  key_fetching[fkey] = true
  key_callbacks[fkey] = { callback }
  -- generation guard: clear_key_cache (a mutation elsewhere) may drop this
  -- fetch's callbacks while the SCAN is in flight, and a NEWER fetch for the
  -- same prefix can start right after — the stale response must neither
  -- overwrite the fresh cache nor answer the new fetch's callbacks
  fetch_gen_counter = fetch_gen_counter + 1
  local my_gen = fetch_gen_counter
  key_fetch_gen[fkey] = my_gen

  local scan_count = config.config.scan_count or 500
  local cmd = { "SCAN", "0", "MATCH", prefix .. "*", "COUNT", tostring(scan_count) }
  session_conn.execute(conn_url, cmd, {
    on_response = function(ev)
      if key_fetch_gen[fkey] ~= my_gen then return end
      -- SCAN reply: {type, value: keys[], cursor} (redis_executor SCAN branch)
      local v = ev.value
      local keys = (v and v.value) or {}
      local candidates = {}
      for _, k in ipairs(keys) do
        if type(k) == "string" and k:sub(1, #prefix) == prefix then
          candidates[#candidates + 1] = k
        end
      end
      table.sort(candidates)
      -- keep completion menus small: SCAN already caps pages at scan_count,
      -- but a 500-entry menu is unusable — surface the first
      -- completion_max_keys (config) only
      local cap = config.config.completion_max_keys or 50
      if #candidates > cap then
        candidates = { unpack(candidates, 1, cap) }
      end
      key_cache[key] = candidates
      flush_key(fkey, candidates)
    end,
    on_error = function()
      if key_fetch_gen[fkey] ~= my_gen then return end
      flush_key(fkey, {})
    end,
  }, nil, { db = db })
end

--- Clear cached key candidates (connection/context changes, schema edits).
function M.clear_key_cache()
  key_cache = {}
  key_fetching = {}
  key_callbacks = {}
  key_fetch_gen = {}  -- in-flight responses fail the gen check and drop
end

--- Drop the connection-name cache (connections.toml changed).
function M.clear_conn_names()
  conn_names_cache = nil
end

M._test = {
  COMMANDS = COMMANDS,
  ensure_conn_names = M.ensure_conn_names,
  ensure_key_candidates = M.ensure_key_candidates,
  clear_key_cache = M.clear_key_cache,
  clear_conn_names = M.clear_conn_names,
}

return M
