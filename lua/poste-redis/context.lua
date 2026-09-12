--- Window-scoped context resolution: what connection + db a window is
--- "about", so every surface (statusline, source winbar, browser winbar,
--- result winbar) can show the context that window actually executes into.
---
--- Priority for the window under the cursor:
---   1. result panel window  → the active tab's stamped meta (per-USE,
---      SELECT-aware — set by exec_run at run time)
---   2. key browser window   → the browser's current connection scope
---      (one connection + one db at a time)
---   3. `.redis` source buf  → the effective USE/SELECT context at the cursor
---      (mirrors what <CR>/visual/file-run resolve), falling back to the
---      global context connection
---   4. anywhere else        → the global session context, if set
---
--- The .redis case is the point: the global `redis_state.context` is set by
--- :PosteRedisContext / a runtime USE, but a file's own USE + SELECT lines
--- (that <CR> honors) can diverge from it — the statusline must reflect the
--- file, not the global.
local parser = require("poste-redis.parser")
local redis_state = require("poste-redis.state")
local util = require("poste-redis.util")

local M = {}

-----------------------------------------------------------------------
-- Pure per-file resolution (the core; buffer-free)
-----------------------------------------------------------------------

--- Walk parser entries up to `line_1` and return the effective context.
--- Mirrors exec_run's runtime semantics: each USE switches the connection
--- (and restarts the db scope), each SELECT within the current section picks
--- the nearest db. An entry ON the cursor line counts, so sitting on a
--- `USE foo` / `SELECT 3` line already previews what it establishes.
---
--- Entries are sorted by start_line (the parser walks lines in order), so
--- the cut point is found by binary search and the effective context by a
--- short backward scan (the last USE/SELECT at or above the cursor decides;
--- a SELECT contributes its db, then the nearest USE above contributes the
--- connection) — O(log n + distance) instead of walking every entry above
--- the cursor on each statusline redraw.
--- @param entries table[] parser entries
--- @param line_1 number 1-based line (context of this line and below)
--- @return { connection = string|nil, db = number|nil }
function M.entries_context(entries, line_1)
  entries = entries or {}
  -- binary search: lo = first entry fully past the cursor
  local lo, hi = 1, #entries + 1
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    local e = entries[mid]
    if e.start_line and e.start_line <= line_1 then lo = mid + 1 else hi = mid end
  end

  local conn, db
  for i = lo - 1, 1, -1 do
    local e = entries[i]
    if e.kind == "use" then
      conn = e.connection
      break  -- the nearest USE above decides; its db scope restarts here
    elseif e.kind == "command" and e.command == "SELECT" and e.tokens and e.tokens[2] then
      local n = tonumber(e.tokens[2])
      if n and db == nil then db = n end  -- the nearest SELECT below the USE
    end
  end
  return { connection = conn, db = db }
end

-----------------------------------------------------------------------
-- Buffer level (cached parse)
-----------------------------------------------------------------------

local entry_cache = {}  -- buf -> { tick, entries, parsed_upto }
local drop_group

--- Parse a buffer's entries, cached on changedtick (statuslines/winbars
--- resolve on every cursor move / keystroke; re-parsing a large file each
--- time is waste). The parse is also bounded by the cursor line and extends
--- incrementally: an edit re-parses lines 1..cursor, cursor moves down parse
--- only the extension, cursor moves up are free.
--- @param buf number
--- @param line_1 number
--- @return table[]
local function buffer_entries_cached(buf, line_1)
  if not vim.api.nvim_buf_is_valid(buf) then return {} end
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local c = entry_cache[buf]
  if c and c.tick == tick and line_1 <= c.parsed_upto then
    return c.entries
  end
  local entries
  if c and c.tick == tick and line_1 > c.parsed_upto then
    -- extend: parse ONLY the extension and shift its line numbers; the
    -- prefix entries stay untouched. A continuation line at the boundary
    -- parses as a standalone fragment, which is harmless — fragments are
    -- never USE/SELECT.
    entries = c.entries
    local ext_lines = vim.api.nvim_buf_get_lines(buf, c.parsed_upto, line_1, false)
    local more = parser.extract_entries(table.concat(ext_lines, "\n"))
    for _, e in ipairs(more) do
      e.start_line = e.start_line and (e.start_line + c.parsed_upto) or e.start_line
      e.end_line = e.end_line and (e.end_line + c.parsed_upto) or e.end_line
      entries[#entries + 1] = e
    end
  else
    entries = parser.buffer_entries(buf, { max_line = line_1 })
  end
  entry_cache[buf] = { tick = tick, entries = entries, parsed_upto = math.max(line_1, c and c.parsed_upto or 0) }
  if not drop_group then
    drop_group = vim.api.nvim_create_augroup("PosteRedisCtxCache", { clear = true })
    vim.api.nvim_create_autocmd("BufDelete", {
      group = drop_group,
      callback = function(a) entry_cache[a.buf] = nil end,
    })
  end
  return entries
end

--- Effective context of a `.redis` buffer at a 1-based line (connection name
--- may be nil — the global-context fallback is applied by the caller).
--- @param buf number
--- @param line_1 number
--- @return { connection = string|nil, db = number|nil }
function M.file_context(buf, line_1)
  return M.entries_context(buffer_entries_cached(buf, line_1), line_1)
end

-----------------------------------------------------------------------
-- Window resolution
-----------------------------------------------------------------------

--- The window's context + which priority branch matched. Priority:
--- result panel > browser > .redis file > global context. Never raises on
--- torn-down panel/browser state. `resolve()` slices the branch away so its
--- shape stays stable for existing callers/specs.
--- @param win number|nil window handle (default: current)
--- @return { connection = string|nil, db = number|nil,
---          branch = "panel"|"browser"|"file"|"global" }
function M.resolve_scoped(win)
  win = win or vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(win) then
    return { connection = nil, db = nil, branch = "global" }
  end
  local buf = vim.api.nvim_win_get_buf(win)

  -- 1. result panel: the active tab carries its own origin context (the
  --    tab's meta.connection/db are stamped per command by exec_run)
  local ok_b, bstate = pcall(require, "poste-redis.buffer.state")
  if ok_b and bstate.buf == buf and bstate.tabs and bstate.tabs[bstate.active] then
    local meta = bstate.tabs[bstate.active].meta
    if meta and (meta.connection or meta.db ~= nil) then
      return { connection = meta.connection, db = meta.db, branch = "panel" }
    end
  end

  -- 2. key browser: its single connection + selected db
  if vim.api.nvim_buf_get_name(buf) == "poste://redis_browser" then
    local ok_i, binit = pcall(require, "poste-redis.browser.init")
    if ok_i and binit.current_scope then
      local s = binit.current_scope() or {}
      return { connection = s.connection, db = s.db, branch = "browser" }
    end
  end

  -- 3. .redis source buffer: the effective context at the cursor
  if vim.api.nvim_get_option_value("filetype", { buf = buf }) == "poste_redis" then
    local line_1 = vim.api.nvim_win_get_cursor(win)[1]
    local fc = M.file_context(buf, line_1)
    if not fc.connection then
      fc.connection = redis_state.context.connection
    end
    if fc.connection then
      return { connection = fc.connection, db = fc.db, branch = "file" }
    end
    return { connection = nil, db = nil, branch = "file" }
  end

  -- 4. anywhere else: the global session context
  return {
    connection = redis_state.context.connection,
    db = redis_state.context.db,
    branch = "global",
  }
end

--- The window's context. Priority: result panel > browser > .redis file >
--- global context. Never raises on torn-down panel/browser state.
--- @param win number|nil window handle (default: current)
--- @return { connection = string|nil, db = number|nil }
function M.resolve(win)
  local r = M.resolve_scoped(win)
  return { connection = r.connection, db = r.db }
end

-----------------------------------------------------------------------
-- Display
-----------------------------------------------------------------------

--- "local db3" style text for a context. A raw connection URL renders as its
--- credential-free host (same rule the result-panel winbar uses).
--- @param ctx table { connection, db }
--- @return string  "" when nothing is resolvable
function M.display(ctx)
  ctx = ctx or {}
  local parts = {}
  local conn = util.host_label(ctx.connection)
  if conn and conn ~= "" then
    parts[#parts + 1] = conn
  end
  if ctx.db ~= nil then
    parts[#parts + 1] = "db" .. tostring(ctx.db)
  end
  return table.concat(parts, " ")
end

M._test = {
  entries_context = M.entries_context,
  file_context = M.file_context,
  display = M.display,
  resolve = M.resolve,
  resolve_scoped = M.resolve_scoped,
}

return M