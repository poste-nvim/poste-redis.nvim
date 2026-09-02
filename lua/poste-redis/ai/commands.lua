--- Slash commands for the "redis" AI context — exposed through poste-ai's
--- command palette (typed "/" in the chat input):
---   /connections  scope the chat to a redis connection (connections.toml)
---   /dbs          scope the chat to a SELECT db of that connection (0..15)

local M = {}

--- /connections — candidates from connections.toml (async).
--- @param prefix string filter by label prefix
--- @param _scope table current chat scope (unused)
--- @param cb function(candidates)
function M.complete_connections(prefix, _scope, cb)
  local connections = require("poste-redis.connections")
  connections.list_connections(function(list)
    local items = {}
    for _, c in ipairs(list or {}) do
      if c.name:sub(1, #prefix) == prefix then
        items[#items + 1] = { label = c.name, description = c.dialect or "redis" }
      end
    end
    cb(items)
  end)
end

--- /dbs — the 16 SELECT dbs; candidates prefixed with the current choice.
--- @param prefix string
--- @param scope table current chat scope snapshot
--- @param cb function(candidates)
function M.complete_dbs(prefix, scope, cb)
  local items = {}
  for db = 0, 15 do
    local label = tostring(db)
    if label:sub(1, #prefix) == prefix then
      items[#items + 1] = { label = label, description = "db " .. (scope and scope.connection or "?") }
    end
  end
  cb(items)
end

--- The commands table handed to poste-ai's context contract.
--- @return table
function M.list()
  local icons = require("poste-redis.icons")
  return {
    {
      name = "connections",
      desc = "scope this chat to a redis connection",
      complete = function(prefix, scope, cb) M.complete_connections(prefix, scope, cb) end,
      run = function(item, api)
        if item and item.label then api.set_scope("connection", item.label, icons.ICON.connection) end
      end,
    },
    {
      name = "dbs",
      desc = "scope this chat to a SELECT db (0-15) of the connection",
      complete = function(prefix, scope, cb) M.complete_dbs(prefix, scope, cb) end,
      run = function(item, api)
        if item and item.label then api.set_scope("database", item.label, icons.ICON.db) end
      end,
    },
  }
end

return M
