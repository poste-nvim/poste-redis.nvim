--- Grid cell editing for the result panel (poste-db dataset pattern):
---   i   edit the cell under the cursor (type-specific write)
---   o   add a row (RPUSH/SADD/HSET/ZADD/SET)
---   dd  delete the row under the cursor (LREM/SREM/HDEL/ZREM/DEL)
--- Every write goes through the persistent redis-session transport with the
--- tab's recorded connection + db, then the tab refreshes itself so the grid
--- always reflects the server.
local session_conn = require("poste-redis.session_conn")
local connections = require("poste-redis.connections")
local util = require("poste-redis.util")

local M = {}

local TITLE = "PosteRedis"

--- Sentinel marker for list row deletion (LSET to it, then LREM the first
--- occurrence). Unlikely-collision constant; redis lists edited through the
--- panel are the target use.
local DELETE_SENTINEL = "__POSTE_DELETE_ROW__"

--- Resolve the tab's connection URL + db.
--- @param tab table
--- @return string|nil url, number|nil db, string|nil err
local function resolve_conn(tab)
  local meta = tab and tab.meta
  if not meta or not meta.connection then
    return nil, nil, "tab has no recorded connection"
  end
  local url, err = connections.resolve(meta.connection)
  return url, meta.db, err
end

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = TITLE })
end

local buffer_refresh = nil  -- set by buffer.lua (M.refresh)

--- What every write ends with: the key-prefix completion cache is stale, and
--- the tab this write came from has to be re-read from the server. The tab is
--- passed on rather than left to the panel, because the user may have switched
--- tabs while the write (or the verification in front of it) was in flight.
local function refresh(tab)
  pcall(function() require("poste-redis.completion.data").clear_key_cache() end)
  if buffer_refresh then buffer_refresh(tab) end
end

--- The key + type a tab is bound to (nil when the tab isn't key-bound).
--- @param tab table
--- @return string|nil key, string|nil type
local function key_context(tab)
  local meta = tab and tab.meta
  local key = meta and meta.key
  local value = meta and meta.value
  local type_name = value and value.type
  if not key or not type_name then return nil, nil end
  return key, type_name
end

--- Raw value of the cell under the cursor (nil on the index column).
--- @param tab table
--- @return any raw, number col, table row_data
local function cursor_cell(tab)
  local pmeta = tab.pmeta
  if not pmeta then return nil, 0, nil end
  local vis_row = tab.cursor.row
  local global_row = (tab.page - 1) * tab.page_size + vis_row
  local row_data = tab.grid.rows[global_row]
  local col = tab.cursor.col
  if not row_data or col < 2 then return nil, col, row_data end
  return row_data[col], col, row_data
end

local function exec(tab, url, cmd, db, on_ok)
  -- Quoted render (util.render_command): edited values often carry whitespace,
  -- and the raw join reads back as separate args in the history line.
  local rendered = util.render_command(cmd)
  session_conn.execute(url, cmd, {
    on_response = function()
      notify(rendered .. " — OK")
      require("poste-redis.history").push({
        command = rendered,
        connection = tab and tab.meta and tab.meta.connection or "",
        db = db,
        kind = "write",
      })
      on_ok()
    end,
    on_error = function(msg)
      notify(rendered .. " failed: " .. tostring(msg), vim.log.levels.ERROR)
    end,
  }, nil, { db = db, owner = "browser" })
end

--- Verify the value currently stored at a list index still matches the
--- rendered cell, then run the write. The grid's index column is the row's
--- position in the RENDERED result, which only equals the true list index
--- when the result started at the list head and nothing shifted since — a
--- stale write would corrupt an unrelated element.
local function verified_list_write(tab, url, key, idx_0, expected, build_cmd, db, on_ok)
  session_conn.execute(url, { "LINDEX", key, tostring(idx_0) }, {
    on_response = function(ev)
      local current = ev.value and ev.value.value
      if tostring(current) ~= tostring(expected) then
        notify("List changed since render — press r to refresh, then retry", vim.log.levels.WARN)
        return
      end
      exec(tab, url, build_cmd(), db, on_ok)
    end,
    on_error = function(msg)
      notify("LINDEX failed: " .. tostring(msg), vim.log.levels.ERROR)
    end,
  }, nil, { db = db, owner = "browser" })
end

--- Edit the cell under the cursor (i). Index column is not editable.
--- @param tab table
function M.edit_cell(tab)
  local key, type_name = key_context(tab)
  if not key then
    notify("This tab is not bound to a key — nothing to edit", vim.log.levels.WARN)
    return
  end
  local url, db, err = resolve_conn(tab)
  if not url then
    notify("Cannot resolve connection: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  local raw, col, row_data = cursor_cell(tab)
  if not raw then
    notify("Move to a value cell to edit it", vim.log.levels.WARN)
    return
  end
  local current = type(raw) == "string" and raw or tostring(raw)

  vim.ui.input({ prompt = ("Edit %s [%s]: "):format(key, type_name), default = current }, function(input)
    if input == nil or input == current then return end
    if type_name == "string" then
      -- KEEPTTL: a bare SET would silently clear the key's expiry — editing a
      -- value must not reset it (ignored on keys without a TTL, redis >= 6)
      exec(tab, url, { "SET", key, input, "KEEPTTL" }, db, function() refresh(tab) end)
    elseif type_name == "hash" then
      -- col 2 = field (editable → HSET new field, DEL old), col 3 = value
      if col == 2 and input ~= row_data[2] then
        exec(tab, url, { "HSET", key, input, row_data[3] or "" }, db, function()
          exec(tab, url, { "HDEL", key, row_data[2] }, db, function() refresh(tab) end)
        end)
      else
        exec(tab, url, { "HSET", key, row_data[2], input }, db, function() refresh(tab) end)
      end
    elseif type_name == "zset" then
      -- col 2 = member (rename → ZADD new score + ZREM old), col 3 = score
      if col == 3 then
        local score = tonumber(input)
        if not score then
          notify("Score must be a number: " .. input, vim.log.levels.ERROR)
          return
        end
        exec(tab, url, { "ZADD", key, tostring(score), row_data[2] }, db, function() refresh(tab) end)
      else
        vim.ui.input({ prompt = "Score for " .. input .. ": ", default = tostring(row_data[3]) },
          function(score)
            if not score or tonumber(score) == nil then
              notify("Score must be a number", vim.log.levels.ERROR)
              return
            end
            exec(tab, url, { "ZADD", key, score, input }, db, function()
              exec(tab, url, { "ZREM", key, row_data[2] }, db, function() refresh(tab) end)
            end)
          end)
      end
    elseif type_name == "list" then
      -- row index (1-based in the grid) → LSET at index-1, verified first
      verified_list_write(tab, url, key, (row_data[1] or 1) - 1, raw, function()
        return { "LSET", key, tostring((row_data[1] or 1) - 1), input }
      end, db, function() refresh(tab) end)
    elseif type_name == "set" then
      exec(tab, url, { "SREM", key, raw }, db, function()
        exec(tab, url, { "SADD", key, input }, db, function() refresh(tab) end)
      end)
    else
      notify("Editing type '" .. tostring(type_name) .. "' is not supported", vim.log.levels.WARN)
    end
  end)
end

--- Delete the row under the cursor (dd).
--- @param tab table
function M.delete_row(tab)
  local key, type_name = key_context(tab)
  if not key then
    notify("This tab is not bound to a key — nothing to delete", vim.log.levels.WARN)
    return
  end
  local url, db, err = resolve_conn(tab)
  if not url then
    notify("Cannot resolve connection: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  local raw, _, row_data = cursor_cell(tab)
  if not raw then
    notify("Move to a value cell to delete its row", vim.log.levels.WARN)
    return
  end

  local choice = vim.fn.confirm(("Delete row  %s  from %s?"):format(
    tostring(type(raw) == "table" and "" or raw), key), "&Yes\n&No", 2, "Warning")
  if choice ~= 1 then
    notify("Deletion cancelled")
    return
  end

  if type_name == "string" then
    exec(tab, url, { "DEL", key }, db, function() refresh(tab) end)
  elseif type_name == "hash" then
    exec(tab, url, { "HDEL", key, row_data[2] }, db, function() refresh(tab) end)
  elseif type_name == "zset" then
    exec(tab, url, { "ZREM", key, row_data[2] }, db, function() refresh(tab) end)
  elseif type_name == "set" then
    exec(tab, url, { "SREM", key, raw }, db, function() refresh(tab) end)
  elseif type_name == "list" then
    -- sentinel + LREM at the rendered index, verified first (same stale-
    -- index hazard as edit_cell)
    local idx = (row_data[1] or 1) - 1
    verified_list_write(tab, url, key, idx, raw, function()
      return { "LSET", key, tostring(idx), DELETE_SENTINEL }
    end, db, function()
      exec(tab, url, { "LREM", key, "1", DELETE_SENTINEL }, db, function() refresh(tab) end)
    end)
  else
    notify("Deleting type '" .. tostring(type_name) .. "' is not supported", vim.log.levels.WARN)
  end
end

--- Add a row (o). Prompts per type; hash needs field+value, zset member+score.
--- @param tab table
function M.add_row(tab)
  local key, type_name = key_context(tab)
  if not key then
    notify("This tab is not bound to a key — nothing to add", vim.log.levels.WARN)
    return
  end
  local url, db, err = resolve_conn(tab)
  if not url then
    notify("Cannot resolve connection: " .. tostring(err), vim.log.levels.ERROR)
    return
  end

  if type_name == "hash" then
    vim.ui.input({ prompt = "New field: " }, function(field)
      if not field or field == "" then return end
      vim.ui.input({ prompt = "Value for " .. field .. ": " }, function(value)
        if value == nil then return end
        exec(tab, url, { "HSET", key, field, value }, db, function() refresh(tab) end)
      end)
    end)
  elseif type_name == "zset" then
    vim.ui.input({ prompt = "New member: " }, function(member)
      if not member or member == "" then return end
      vim.ui.input({ prompt = "Score for " .. member .. ": ", default = "0" }, function(score)
        if not score or tonumber(score) == nil then
          notify("Score must be a number", vim.log.levels.ERROR)
          return
        end
        exec(tab, url, { "ZADD", key, score, member }, db, function() refresh(tab) end)
      end)
    end)
  else
    -- string (overwrite, KEEPTTL — same no-TTL-reset rule as edit_cell) /
    -- list (RPUSH) / set (SADD)
    local verb = type_name == "list" and "RPUSH" or type_name == "set" and "SADD" or "SET"
    vim.ui.input({ prompt = ("Value to %s on %s: "):format(verb, key) }, function(value)
      if value == nil or value == "" then return end
      local cmd = { verb, key, value }
      if verb == "SET" then cmd[#cmd + 1] = "KEEPTTL" end
      exec(tab, url, cmd, db, function() refresh(tab) end)
    end)
  end
end

--- Wire the refresh used after writes (set once by buffer.lua). It is called
--- with the tab the write came from.
function M.set_refresh(fn)
  buffer_refresh = fn
end

M._test = {
  resolve_conn = resolve_conn,
  key_context = key_context,
  cursor_cell = cursor_cell,
  DELETE_SENTINEL = DELETE_SENTINEL,
  set_buffer_refresh = M.set_refresh,
}

return M
