--- Browser node info (`i` on a node): what's under it, memory, TTL, encoding.
--- Key nodes: TYPE / ENCODING / MEMORY USAGE / TTL. Group nodes: key count
--- under the prefix (SCAN MATCH) + summed MEMORY USAGE (capped sample).
--- DB nodes: DBSIZE. Rendered in a markdown float (doc preview pattern).
local session_conn = require("poste-redis.session_conn")
local doc = require("poste-redis.doc")
local redis_state = require("poste-redis.state")
local icons = require("poste-redis.icons")

local M = {}

--- Byte count humanizer (B / KB / MB / GB).
--- @param bytes number
--- @return string
function M.format_bytes(bytes)
  if type(bytes) ~= "number" or bytes < 0 then return "?" end
  local units = { "B", "KB", "MB", "GB", "TB" }
  local v = bytes
  for i = 1, #units do
    if v < 1024 or i == #units then
      if i == 1 then
        return string.format("%d B", v)
      end
      return string.format("%.1f %s", v, units[i])
    end
    v = v / 1024
  end
  return tostring(bytes)
end

--- Gather info lines for a key node (single round of session commands).
--- @param node table  key node
--- @param url string
--- @param cb fun(lines: string[])
local function key_info(node, url, cb)
  local key = node.meta.key
  local db = node.meta.db or 0
  local out = { type = "?", encoding = nil, memory = nil, ttl = nil }
  local pending = 4

  local function done()
    if pending > 0 then return end
    local lines = {
      "### " .. (icons.KEY_ICON[out.type] or "") .. " " .. key,
      "",
      "- type: **" .. tostring(out.type) .. "**",
    }
    if out.encoding then lines[#lines + 1] = "- encoding: " .. out.encoding end
    if out.memory ~= nil then
      lines[#lines + 1] = ("- memory: %s (%d bytes)"):format(M.format_bytes(out.memory), out.memory)
    end
    if out.ttl ~= nil then
      lines[#lines + 1] = out.ttl < 0 and "- ttl: none (persistent)" or ("- ttl: " .. out.ttl .. "s")
    end
    cb(lines)
  end

  local function one(kind, cmd, handle)
    session_conn.execute(url, cmd, {
      on_response = function(ev)
        out[kind] = handle and handle(ev.value) or (ev.value and ev.value.value)
        pending = pending - 1
        done()
      end,
      on_error = function()
        pending = pending - 1
        done()
      end,
    }, nil, { db = db })
  end

  one("type", { "TYPE", key }, function(v) return v and v.value end)
  one("encoding", { "OBJECT", "ENCODING", key }, function(v) return v and v.value end)
  one("memory", { "MEMORY", "USAGE", key }, function(v) return v and v.value end)
  one("ttl", { "TTL", key }, function(v) return v and v.value end)
end

--- Gather info lines for a group node: key count under the prefix + summed
--- memory over a capped sample (a 100k-key group must not probe every key).
--- @param node table  group node
--- @param url string
--- @param cb fun(lines: string[])
local function group_info(node, url, cb)
  local prefix = node.meta.prefix or ""
  local db = node.meta.db or 0
  local match = prefix .. ":*"
  local count = 0
  local memory = 0
  local sampled = 0
  local pending_samples = 0
  local scan_done = false
  local finished = false

  local function maybe_done()
    if finished or not scan_done or pending_samples > 0 then return end
    finished = true
    local lines = {
      "### " .. icons.ICON.group .. " " .. prefix .. "/",
      "",
      ("- keys: **%d**"):format(count),
    }
    if sampled > 0 then
      local avg = memory / sampled
      lines[#lines + 1] = ("- estimated memory: ~%s (%d keys sampled, avg %s/key)")
        :format(M.format_bytes(avg * count), sampled, M.format_bytes(avg))
    end
    cb(lines)
  end

  local function sample(k)
    if sampled >= GROUP_SAMPLE_CAP then return end
    sampled = sampled + 1
    pending_samples = pending_samples + 1
    session_conn.execute(url, { "MEMORY", "USAGE", k }, {
      on_response = function(mv)
        memory = memory + (mv.value and mv.value.value or 0)
        pending_samples = pending_samples - 1
        maybe_done()
      end,
      on_error = function()
        pending_samples = pending_samples - 1
        maybe_done()
      end,
    }, nil, { db = db })
  end

  local function next_page(cursor)
    session_conn.execute(url, { "SCAN", cursor, "COUNT", "5000", "MATCH", match }, {
      on_response = function(ev)
        local keys = ev.value and ev.value.value or {}
        count = count + #keys
        for _, k in ipairs(keys) do sample(k) end
        local cursor2 = (ev.value and ev.value.cursor) or "0"
        if cursor2 == "0" or count >= 1000000 then
          scan_done = true
          maybe_done()
        else
          next_page(cursor2)
        end
      end,
      on_error = function(msg)
        finished = true
        cb({ "### " .. prefix .. "/", "", "- scan failed: " .. tostring(msg) })
      end,
    }, nil, { db = db })
  end

  next_page("0")
end

--- Show the info float for the node under the cursor.
--- @param node table
--- @param ctx table  { url = string }
function M.show(node, ctx)
  if not node or not ctx or not ctx.url then return end
  local cb = function(lines)
    doc.open_doc_preview(lines, {
      title = " node info ",
      track_key = "info:" .. tostring(node.full_name),
    })
  end
  if node.node_type == "key" then
    key_info(node, ctx.url, cb)
  elseif node.node_type == "group" then
    group_info(node, ctx.url, cb)
  elseif node.node_type == "db" then
    session_conn.execute(ctx.url, { "DBSIZE" }, {
      on_response = function(ev)
        cb({ "### db " .. tostring(node.meta.db or 0), "",
          ("- keys: **%s**"):format(tostring(ev.value and ev.value.value)) })
      end,
    }, nil, { db = node.meta.db })
  end
end

M._test = {
  format_bytes = M.format_bytes,
  GROUP_SAMPLE_CAP = GROUP_SAMPLE_CAP,
}

return M
