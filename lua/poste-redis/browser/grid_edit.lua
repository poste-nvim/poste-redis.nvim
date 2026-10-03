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
  -- RESP3 spells a hash "map"; the renderer's grid builders already accept
  -- both, and the editors must too — the edit commands (HSET/HDEL/HEXISTS)
  -- are identical. Without this an unknown spelling fell through add_row's
  -- verb fallback to `SET`, replacing the whole collection with a string.
  if type_name == "map" then type_name = "hash" end
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
      -- The rejected write records itself, like the browser's key-level
      -- actions: `history.activate` renders the ERROR block for it, and the
      -- sidebar shows ✗. The read probes on this path (LINDEX, HEXISTS/ZSCORE)
      -- stay unrecorded — a failure there changed nothing.
      require("poste-redis.history").push({
        command = rendered,
        connection = tab and tab.meta and tab.meta.connection or "",
        db = db,
        kind = "write",
        status = "error",
        error = tostring(msg),
      })
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

--- Does a name-free probe reply say the name is taken? HEXISTS and SISMEMBER
--- answer with the integer 0/1; ZSCORE answers with the member's score, or a
--- nil reply when the member does not exist.
local function name_taken(verb, ev)
  local v = ev and ev.value
  if not v then return false end
  if verb == "HEXISTS" or verb == "SISMEMBER" then return tonumber(v.value) == 1 end
  return v.type ~= "nil" and v.value ~= nil
end

--- Probe that a name is free before a write that would otherwise clobber
--- whatever already holds it. Renaming a hash field (a zset member, a set
--- member) onto an existing name overwrites or loses that entry and then
--- deletes the original, so one edit silently destroys a member; the probe
--- runs first and the write only runs through `on_clear`.
local function guard_name_free(url, key, db, probe, taken_msg, on_clear)
  local verb = probe[1]
  session_conn.execute(url, probe, {
    on_response = function(ev)
      if name_taken(verb, ev) then
        notify(taken_msg, vim.log.levels.WARN)
        return
      end
      on_clear()
    end,
    on_error = function(msg)
      notify(verb .. " failed: " .. tostring(msg), vim.log.levels.ERROR)
    end,
  }, nil, { db = db, owner = "browser" })
end

--- Why this row's name cannot go on the wire, or nil when it can.
---
--- A name-bound write sends the cell's TEXT as the command argument, so it
--- works only while that text is the real name. A non-UTF-8 field name or
--- zset member renders as `hex:…` (and a set member as `(binary) N bytes
--- hex: …`, since set members arrive through the value path) — text that is
--- for reading only: HSET/ZADD with it creates a SECOND entry named after the
--- rendering, while HDEL/ZREM/SREM delete nothing and still answer OK, so the
--- refresh leaves the row exactly where it was.
---
--- A binary VALUE cell is not a reason to refuse: the row's name still
--- addresses it, and replacing those bytes with typed text is what the user
--- asked for. Lists never come here — their writes are index-addressed and
--- verified with LINDEX.
--- @param type_name string
--- @param row_data table|nil  the row's raw cells (name column at [2])
--- @return string|nil reason
local function display_only_name(type_name, row_data)
  if type_name ~= "hash" and type_name ~= "zset" and type_name ~= "set" then
    return nil
  end
  local name = row_data and row_data[2]
  if not util.is_hex_display(name) then return nil end
  return ("'%s' is how a non-UTF-8 name renders — it is not the name on the "
    .. "server, so this row cannot be edited or deleted from the grid. "
    .. "Send the command yourself, with the bytes escaped"):format(tostring(name))
end

--- Why this row's VALUE cell is a display-capped prefix of the stored string
--- rather than the whole of it, or nil. The binary caps every string reply at
--- `--max-bytes` (65536 by default), so a list element or hash value past the
--- cap arrives as its first N bytes — and a write built from the cell cannot
--- see the cut: an LSET/HSET stores the prefix as the WHOLE value, and (the
--- verification being capped by the same limit on both sides) the list's
--- LINDEX check compares two identical prefixes and passes. A truncated SET
--- member's SREM addresses text that matches nothing. The executor flags such
--- rows per item (`item_truncated` for list/set cells, `value_truncated` for
--- hash values, 1:1 with the rows and absent when nothing was cut); writes
--- that would put a cell's text back are refused here — the same trade the
--- string type's own `truncated` guard makes.
--- @param value table|nil  the tab's raw result value (meta.value)
--- @param row_data table|nil  the row's raw cells (index column at [1])
--- @param consequence string  the refusal's second half, naming the action
--- @return string|nil reason
local function truncated_value_reason(value, row_data, consequence)
  if type(value) ~= "table" or type(row_data) ~= "table" then return nil end
  local idx = row_data[1]
  if type(idx) ~= "number" then return nil end
  local flags = value.item_truncated or value.value_truncated
  if type(flags) == "table" and flags[idx] == true then
    return "This cell is longer than the display cap, so the panel only holds "
      .. "its prefix — " .. consequence
  end
  return nil
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
  local meta_value = tab.meta and tab.meta.value
  local reason = display_only_name(type_name, row_data)
    or truncated_value_reason(meta_value, row_data,
      -- a hash rename also stores the value cell in the NEW field, so the
      -- whole row is refused, not just the value column
      "editing would store that prefix as the whole value")
  if type_name == "string" and meta_value and meta_value.truncated then
    -- the transport capped the value, so the cell holds a PREFIX of it — and
    -- `SET key <prefix>` would cut the key down to what fit on screen
    reason = "This value is longer than the display cap, so the panel only holds its "
      .. "prefix — editing would store that prefix as the whole value"
  end
  if reason then
    notify(reason, vim.log.levels.WARN)
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
        guard_name_free(url, key, db, { "HEXISTS", key, input },
          ("Field '%s' already exists — edit that row instead of renaming onto it"):format(input),
          function()
            exec(tab, url, { "HSET", key, input, row_data[3] or "" }, db, function()
              exec(tab, url, { "HDEL", key, row_data[2] }, db, function() refresh(tab) end)
            end)
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
            guard_name_free(url, key, db, { "ZSCORE", key, input },
              ("Member '%s' already exists — edit that row instead of renaming onto it"):format(input),
              function()
                exec(tab, url, { "ZADD", key, score, input }, db, function()
                  exec(tab, url, { "ZREM", key, row_data[2] }, db, function() refresh(tab) end)
                end)
              end)
          end)
      end
    elseif type_name == "list" then
      -- row index (1-based in the grid) → LSET at index-1, verified first
      verified_list_write(tab, url, key, (row_data[1] or 1) - 1, raw, function()
        return { "LSET", key, tostring((row_data[1] or 1) - 1), input }
      end, db, function() refresh(tab) end)
    elseif type_name == "set" then
      -- Renaming a member onto one that already exists loses the SOURCE
      -- member: SREM removes it, then SADD finds the target present and adds
      -- nothing — same one-edit-destroys-one shape the hash/zset renames
      -- probe for (the guard_name_free doc says it for hash/zset).
      guard_name_free(url, key, db, { "SISMEMBER", key, input },
        ("Member '%s' already exists — delete that row instead of renaming onto it"):format(input),
        function()
          exec(tab, url, { "SREM", key, raw }, db, function()
            exec(tab, url, { "SADD", key, input }, db, function() refresh(tab) end)
          end)
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
  local reason = display_only_name(type_name, row_data)
  if not reason and type_name == "set" then
    -- Only the set's delete consumes the CELL TEXT (SREM <raw>): list dd is
    -- index-addressed, hash/zset delete by the field/member name, which is
    -- never capped — so the truncation guard is a set-row affair here.
    reason = truncated_value_reason(tab.meta and tab.meta.value, row_data,
      "this prefix is not the member on the server, so this row cannot be "
      .. "deleted from the grid")
  end
  if reason then
    notify(reason, vim.log.levels.WARN)
    return
  end

  -- A string key is a single row, so dd deletes the KEY itself; asking about
  -- "row <value>" read like one cell of a bigger value could survive it.
  local subject = type_name == "string"
      and ("the whole value of  %s  (DEL)"):format(key)
      or ("row  %s  from %s"):format(tostring(type(raw) == "table" and "" or raw), key)
  local choice = vim.fn.confirm(("Delete %s?"):format(subject), "&Yes\n&No", 2, "Warning")
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
        -- adding a row that already exists is a mistake, not an update: HSET
        -- would replace the other field's value with no warning
        guard_name_free(url, key, db, { "HEXISTS", key, field },
          ("Field '%s' already exists — press i on that row to edit its value"):format(field),
          function()
            exec(tab, url, { "HSET", key, field, value }, db, function() refresh(tab) end)
          end)
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
        guard_name_free(url, key, db, { "ZSCORE", key, member },
          ("Member '%s' already exists — press i on that row to edit its score"):format(member),
          function()
            exec(tab, url, { "ZADD", key, score, member }, db, function() refresh(tab) end)
          end)
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
