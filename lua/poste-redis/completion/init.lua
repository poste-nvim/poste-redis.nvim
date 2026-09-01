--- Redis completion — orchestrator.
---
--- Provides completion for the `poste_redis` filetype through a blink.cmp
--- source provider (and an nvim-cmp source for legacy setups) by:
---   1. classifying the cursor context (command / USE connection / key arg)
---   2. fetching candidates from the matching source (command table,
---      connections.toml, SCAN MATCH key prefixes)
---   3. returning deduplicated items to the completion engine
---
--- Pattern rebuilt from poste-db's completion orchestrator — no cross-satellite
--- require (red line).
local ctx = require("poste-redis.completion.ctx")
local data = require("poste-redis.completion.data")
local exec_run = require("poste-redis.exec_run")

local M = {}

--- Completion item kinds (LSP): 3=Function, 6=Class, 1=Text, 10=Variable.
local KIND_COMMAND = 3
local KIND_CONNECTION = 6
local KIND_KEY = 1

---------------------------------------------------------------------------
-- Item assembly
---------------------------------------------------------------------------

--- Command-name position → built-in command table.
local function command_items(prefix)
  return ctx.filter(ctx.make_items(data.COMMANDS, KIND_COMMAND, "command: "), prefix)
end

--- After `USE` → connection names from connections.toml.
local function connection_items(prefix, callback)
  data.ensure_conn_names(function(names)
    callback(ctx.filter(ctx.make_items(names, KIND_CONNECTION, "connection: "), prefix))
  end)
end

--- Argument position → key prefix candidates via SCAN MATCH (async).
--- Resolves the connection for the buffer; no connection → no candidates.
local function key_items(buf, prefix, callback)
  local url, _ = exec_run._connection_for(buf)
  if not url then
    callback({})
    return
  end
  local db = require("poste-redis.state").context.db
  data.ensure_key_candidates(url, prefix, db, function(candidates)
    callback(ctx.filter(ctx.make_items(candidates, KIND_KEY, "key: "), prefix))
  end)
end

--- Assemble completion items for a buffer + line-before-cursor.
--- @param buf number
--- @param line_before string
--- @param callback fun(items: table[])
function M.get_items(buf, line_before, callback)
  local d = ctx.detect(line_before)
  if d.kind == "none" then callback({}); return end
  if d.kind == "command" then callback(command_items(d.prefix)); return end
  if d.kind == "connection" then connection_items(d.prefix, callback); return end
  key_items(buf, d.prefix, callback)
end

--------------------------------------------------------------------------
-- blink.cmp interface
--------------------------------------------------------------------------

function M.new(opts)
  return setmetatable({ opts = opts or {} }, { __index = M })
end

function M:enabled()
  return vim.bo.filetype == "poste_redis"
end

function M:get_trigger_characters()
  return { ":", " " }
end

function M:get_keyword_length(blink_ctx)
  if not blink_ctx or not blink_ctx.cursor then return 0 end
  local line = blink_ctx.line or ""
  local col = blink_ctx.cursor[2]
  local before = line:sub(1, col)
  local prefix = before:match("[%w:_*.-]*$") or ""
  return #prefix
end

local completion_gen = 0

function M:get_completions(blink_ctx, callback)
  completion_gen = completion_gen + 1
  local my_gen = completion_gen

  local buf = vim.api.nvim_get_current_buf()
  local cursor_line, cursor_col, line
  if blink_ctx and blink_ctx.cursor then
    cursor_line = blink_ctx.cursor[1]
    cursor_col = blink_ctx.cursor[2]
    line = blink_ctx.line or ""
  else
    cursor_line = vim.fn.line(".")
    cursor_col = vim.fn.col(".")
    line = vim.api.nvim_get_current_line()
  end
  local line_before = line:sub(1, cursor_col)

  M.get_items(buf, line_before, function(items)
    if my_gen ~= completion_gen then return end
    local seen = {}
    local deduped = {}
    for _, item in ipairs(items) do
      if not seen[item.label] then
        seen[item.label] = true
        table.insert(deduped, item)
      end
    end
    callback({ is_incomplete_forward = true, is_incomplete_backward = true, items = deduped })
  end)
end

function M:resolve(item, callback) callback(item) end

function M:execute(exec_ctx, item, callback, default_impl)
  if default_impl then default_impl() end
  callback()
end

--------------------------------------------------------------------------
-- nvim-cmp interface (legacy fallback)
--------------------------------------------------------------------------

M.source = {}
function M.source.new() return setmetatable({}, { __index = M.source }) end

function M.source:is_available()
  return vim.bo.filetype == "poste_redis"
end

function M.source:get_trigger_characters() return { ":", " " } end

function M.source:execute(entry, callback)
  callback()
end

function M.source:complete(params, callback)
  local line_before = params.context.cursor_before_line or ""
  local buf = vim.api.nvim_get_current_buf()
  M.get_items(buf, line_before, function(items)
    callback({ items = items, isIncomplete = false })
  end)
end

--------------------------------------------------------------------------
-- Test interface
--------------------------------------------------------------------------

M._test = {
  get_items = M.get_items,
  command_items = command_items,
  connection_items = connection_items,
  key_items = key_items,
  KIND_COMMAND = KIND_COMMAND,
  KIND_CONNECTION = KIND_CONNECTION,
  KIND_KEY = KIND_KEY,
}

return M
