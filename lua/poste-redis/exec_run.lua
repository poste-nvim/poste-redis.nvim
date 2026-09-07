--- Redis execution transport. M1 uses the `poste redis-exec` one-shot
--- subcommand only (EXECUTION-PLAN D4); `redis-session` lands in M2.
---
--- Contract (crates/poste-cli/src/redis_exec.rs):
---   stdin:  single JSON line {"connection":"redis://...", "commands":[["GET","k"],...]}
---   stdout: newline-delimited events — progress | result | summary
---   - `result.status` is redis-cli style status text; a failed command sets
---     status="error" + `error` and the batch continues (greedy)
--- Note: the subcommand has no `--json` flag — its output is always NDJSON.
local cli = require("poste.cli")
local parser = require("poste-redis.parser")
local util = require("poste-redis.util")
local redis_state = require("poste-redis.state")
local config = require("poste-redis.config")

local M = {}

-----------------------------------------------------------------------
-- Stale guard + busy bookkeeping
-----------------------------------------------------------------------

local exec_seq = 0    -- monotonic; callbacks from a superseded run are dropped
local active = {}     -- seq -> job_id
local busy = false

--- Current execution sequence number.
function M.seq_of()
  return exec_seq
end

--- Whether any execution is in flight.
function M.is_busy()
  return busy
end

--- Stop every in-flight job and clear busy immediately (Esc/q cancel path —
--- red line #4: busy state must never get stuck).
function M.cancel()
  exec_seq = exec_seq + 1
  local ids = {}
  for _, id in pairs(active) do ids[#ids + 1] = id end
  active = {}
  busy = false
  for _, id in ipairs(ids) do
    pcall(vim.fn.jobstop, id)
  end
end

-----------------------------------------------------------------------
-- Callback plumbing
-----------------------------------------------------------------------

--- Call a user callback guarded: pcall'd and dropped when a newer execution
--- superseded this one. Job callbacks (on_stdout/on_exit) already run on the
--- main loop, so no extra vim.schedule — a schedule added mid-wait is not
--- pumped by vim.wait in headless plenary runs, which made nested callbacks
--- never fire in tests.
local function guarded(my_seq, fn, ...)
  local args = { ... }
  return function()
    if not fn then return end
    if my_seq ~= exec_seq then return end
    local ok, err = pcall(fn, unpack(args))
    if not ok then
      vim.notify("PosteRedis callback error: " .. tostring(err), vim.log.levels.ERROR,
        { title = redis_state.TITLE })
    end
  end
end

--- Decode a single stdout line (NDJSON), returning a table or nil.
local function decode_line(line)
  if not line or line == "" then return nil end
  local ok, ev = pcall(vim.json.decode, line)
  if ok and type(ev) == "table" then return ev end
  return nil
end

-----------------------------------------------------------------------
-- Async execution
-----------------------------------------------------------------------

--- Run a batch of parser entries against one connection.
---
--- @param entries table[]  parser entries (kind == "command")
--- @param opts table
---   - connection: string  redis:// URL (required)
---   - db: number|nil  preselect a db by prepending `SELECT <db>` to the
---     payload; that SELECT's result is swallowed and later result seqs are
---     renumbered, so callers stay entry-aligned (no phantom tab/indicator)
---   - max_items: number|nil  `--max-items` (default from binary: 1000)
---   - max_bytes: number|nil  `--max-bytes` (default: config.preview_max_bytes)
--- @param callbacks table
---   - on_progress(index, total, command)
---   - on_result(result_event)
---   - on_summary(summary_event)
---   - on_error(message, stderr)  process-level failure
--- @return number|nil seq  nil when no job was started
function M.run_async(entries, opts, callbacks)
  opts = opts or {}
  callbacks = callbacks or {}
  local my_seq = exec_seq
  if not opts.connection then
    guarded(my_seq, callbacks.on_error,
      "No connection resolved — run :PosteRedisConnection or add a USE line", "")()
    return nil
  end
  if not vim.tbl_isempty(entries) and opts.connection:sub(1, 8) ~= "redis://"
    and opts.connection:sub(1, 9) ~= "rediss://" then
    guarded(my_seq, callbacks.on_error,
      "Connection is not a redis URL: " .. util.redact_url(opts.connection), "")()
    return nil
  end

  local commands = {}
  for _, e in ipairs(entries or {}) do
    if e.kind == "command" then
      commands[#commands + 1] = parser.entry_args(e)
    end
  end
  if #commands == 0 then
    guarded(my_seq, callbacks.on_error, "Nothing to execute", "")()
    return nil
  end

  -- Preselected db: every fresh redis-exec connection starts on db 0, so a
  -- batch runs on the file-declared db by prepending its SELECT. The
  -- injected SELECT's own result is swallowed (see on_stdout below).
  if opts.db then
    table.insert(commands, 1, { "SELECT", tostring(opts.db) })
  end

  -- Per-command db tracking: SELECT rebinds inside the batch (only on
  -- success — a failed SELECT leaves the session db unchanged) and the
  -- running db is stamped onto each forwarded result so the panel can show
  -- (and act with) the tab's real context.
  local select_targets = {}
  for i, args in ipairs(commands) do
    if args[1] == "SELECT" then select_targets[i] = tonumber(args[2]) end
  end
  local db = 0
  local payload_idx = 0

  local payload = vim.json.encode({
    connection = opts.connection,
    commands = commands,
  })

  local cmd = { "redis-exec" }
  local max_items = opts.max_items
  local max_bytes = opts.max_bytes or config.config.preview_max_bytes
  if max_items then cmd[#cmd + 1] = "--max-items"; cmd[#cmd + 1] = tostring(max_items) end
  if max_bytes then cmd[#cmd + 1] = "--max-bytes"; cmd[#cmd + 1] = tostring(max_bytes) end

  exec_seq = exec_seq + 1
  local run_seq = exec_seq
  busy = true

  local results = {}
  local summary = nil
  local stderr = {}
  local saw_summary = false

  local job_id = cli.run_async(cmd, {
    stdin = payload,
    on_stdout = function(data)
      for _, line in ipairs(data or {}) do
        local ev = decode_line(line)
        if not ev then goto continue end
        if ev.type == "progress" then
          guarded(run_seq, callbacks.on_progress, ev.index, ev.total, ev.command)()
        elseif ev.type == "result" then
          payload_idx = payload_idx + 1
          local is_injected = opts.db and payload_idx == 1
          ev.db = db  -- the db this command ran on (rebind applies to the NEXT)
          if select_targets[payload_idx] and not (ev.status == "error" or ev.error) then
            db = select_targets[payload_idx]
          end
          if is_injected then
            goto continue  -- swallowed: callers stay aligned with their entries
          end
          if opts.db then ev.seq = #results + 1 end  -- renumber past the SELECT
          results[#results + 1] = ev
          guarded(run_seq, callbacks.on_result, ev)()
        elseif ev.type == "summary" then
          summary = ev
          saw_summary = true
          guarded(run_seq, callbacks.on_summary, ev)()
        end
        ::continue::
      end
    end,
    on_stderr = function(data)
      for _, line in ipairs(data or {}) do
        if line ~= "" then stderr[#stderr + 1] = line end
      end
    end,
    on_exit = function(code)
      if run_seq ~= exec_seq then return end
      active[run_seq] = nil
      busy = false
      if saw_summary then
        guarded(run_seq, callbacks.on_done, results, summary)()
      else
        local msg = #stderr > 0 and table.concat(stderr, "\n")
          or ("redis-exec exited with code " .. code)
        guarded(run_seq, callbacks.on_error, msg, table.concat(stderr, "\n"))()
        guarded(run_seq, callbacks.on_done, results, summary)()
      end
    end,
  })

  if job_id == nil or job_id < 0 then
    busy = false
    exec_seq = exec_seq + 1
    guarded(run_seq, callbacks.on_error,
      "Failed to start redis-exec — is the poste binary built? Run cargo build --release in poste.nvim", "")()
    return nil
  end

  active[run_seq] = job_id
  guarded(run_seq, callbacks.on_start, run_seq, job_id)()

  return run_seq
end

-----------------------------------------------------------------------
-- Sync single-command execution (info-type calls)
-----------------------------------------------------------------------

--- Run one entry synchronously via poste.cli.run and return the result event.
--- Blocking — only for information queries, never the <CR> path.
--- @param entry table parser entry
--- @param opts table { connection = string }
--- @return table|nil, string|nil result_event, error
function M.run_sync(entry, opts)
  opts = opts or {}
  if not opts.connection then return nil, "No connection resolved" end
  if entry.kind ~= "command" then return nil, "Not a command entry" end
  local payload = vim.json.encode({
    connection = opts.connection,
    commands = { parser.entry_args(entry) },
  })
  local cmd = { "redis-exec" }
  cmd[#cmd + 1] = "--max-bytes"
  cmd[#cmd + 1] = tostring(opts.max_bytes or config.config.preview_max_bytes)
  local output, err = cli.run(cmd, { stdin = payload })
  if not output then return nil, err end
  for _, line in ipairs(vim.split(output, "\n", { plain = true })) do
    local ev = decode_line(line)
    if ev and ev.type == "result" then return ev, nil end
  end
  return nil, "redis-exec produced no result event"
end

-----------------------------------------------------------------------
-- File execution (USE grouping)
-----------------------------------------------------------------------

--- Group parser entries into per-connection batches by walking USE directives.
--- Commands before any USE fall back to `default_url` when given (the current
--- context / :PosteRedisConnection selection), otherwise become error groups.
--- @param entries table[]
--- @param resolve fun(name: string): string|nil, string|nil
--- @param default_url string|nil
--- @return table[] groups  { connection, entries, start_line, error }
function M.group_by_connection(entries, resolve, default_url)
  resolve = resolve or function(name) return require("poste-redis.connections").resolve(name) end
  local groups = {}
  local current = nil
  local function ensure_current(e)
    if current then return end
    if default_url then
      current = { connection = default_url, entries = {} }
    else
      groups[#groups + 1] = {
        error = ("No connection for line %d — add a USE directive or :PosteRedisConnection"):format(e.start_line),
        start_line = e.start_line,
      }
    end
  end
  for _, e in ipairs(entries) do
    if e.kind == "use" then
      if current then
        groups[#groups + 1] = current
        current = nil
      end
      if e.connection == nil then
        groups[#groups + 1] = {
          error = "Bare USE at line " .. e.start_line .. " — use :PosteRedisConnection",
          start_line = e.start_line,
        }
      else
        local url, err = resolve(e.connection)
        if not url then
          groups[#groups + 1] = {
            error = ("USE %s failed at line %d: %s"):format(e.connection, e.start_line, err),
            start_line = e.start_line,
          }
        else
          current = { connection = url, connection_name = e.connection, entries = {} }
        end
      end
    else
      ensure_current(e)
      if current then
        current.entries[#current.entries + 1] = e
      end
    end
  end
  if current then groups[#groups + 1] = current end
  return groups
end

--- Run one group (per-connection batch), then dispatch the next — multi-USE
--- files execute sequentially so batches never interleave in the UI.
--- Chain validity: run_async's own captured-seq guards stop each batch when a
--- newer run supersedes it, so this only ever continues while the run is
--- current. The one extra check covers the SYNCHRONOUS path — a
--- callbacks.on_group that cancels/supersedes mid-chain (fire-time guards
--- here compare the seq with itself, so they cannot drop anything).
--- Consecutive error groups advance in a while loop — a file of 10k failed
--- USEs must not nest 10k stack frames; real batches re-enter on a fresh
--- stack via their async on_done.
--- @param groups table[]
--- @param index number  1-based group to dispatch
--- @param opts table
--- @param callbacks table
--- @param all_results table[]  accumulated result events
--- @param all_summaries table[]  accumulated summary events
local function dispatch_group(groups, index, opts, callbacks, all_results, all_summaries)
  while index <= #groups do
    local g = groups[index]
    if not g.error then break end
    local err_ev = {
      type = "result",
      status = "error",
      error = g.error,
      command = "",
      start_line = g.start_line,
    }
    all_results[#all_results + 1] = err_ev
    local seq_before = exec_seq
    guarded(exec_seq, callbacks.on_result, err_ev)()
    -- the callback may have canceled/superseded the run; only continue the
    -- synchronous chain while the seq is unchanged
    if exec_seq ~= seq_before then return end
    index = index + 1
  end
  if index > #groups then
    guarded(exec_seq, callbacks.on_done, all_results, all_summaries)()
    return
  end
  local g = groups[index]
  local seq_before = exec_seq
  guarded(exec_seq, callbacks.on_group, g)()
  -- never dispatch a batch for a seq the callback just superseded
  if exec_seq ~= seq_before then return end
  -- "force": the group's USE-resolved connection must win over the run-level
  -- default — "keep" let opts.connection override every later USE group, so
  -- a default URL silently ran the whole file against one connection
  local group_opts = vim.tbl_extend("force", opts or {}, { connection = g.connection })
  -- results ↔ entries are 1:1 per batch (greedy: failed commands still emit),
  -- so stamp each result with its source entry's line. The binary's `seq`
  -- restarts at 1 per batch — callers mapping seq onto a whole-file line list
  -- misplace every group after the first in multi-USE files.
  local group_result_idx = 0
  M.run_async(g.entries, group_opts, {
    on_start = callbacks.on_start,
    on_progress = callbacks.on_progress,
    on_result = function(ev)
      -- which USE group produced this result (nil for the default URL) —
      -- the panel stamps it per tab so multi-USE files show real contexts
      ev.connection_name = g.connection_name
      group_result_idx = group_result_idx + 1
      local src_entry = g.entries[group_result_idx]
      if src_entry and src_entry.start_line then ev.src_line = src_entry.start_line end
      all_results[#all_results + 1] = ev
      guarded(exec_seq, callbacks.on_result, ev)()
    end,
    on_summary = function(ev)
      all_summaries[#all_summaries + 1] = ev
      guarded(exec_seq, callbacks.on_summary, ev)()
    end,
    on_error = function(msg, err)
      guarded(exec_seq, callbacks.on_error, msg, err)()
    end,
    on_done = function()
      dispatch_group(groups, index + 1, opts, callbacks, all_results, all_summaries)
    end,
  })
end

--- Execute a whole .redis buffer, honoring USE, running groups sequentially.
--- @param buf number
--- @param opts table  same as run_async, plus connection (default URL for
---   commands before any USE) and resolve_url(name) → url, err
--- @param callbacks table  on_group, on_result, on_summary, on_error,
---   on_done(all_results, all_summaries)
--- @return number|nil seq of the last started batch
function M.run_file_async(buf, opts, callbacks)
  opts = opts or {}
  callbacks = callbacks or {}
  local entries = parser.buffer_entries(buf)
  local groups = M.group_by_connection(entries, opts.resolve_url, opts.connection)
  dispatch_group(groups, 1, opts, callbacks, {}, {})
  return exec_seq
end

--- Convenience: run the entry under the cursor (or visual range).
--- @param buf number
--- @param mode "cursor"|"visual"
--- @param opts table
--- @param callbacks table
--- @return number|nil seq
function M.run_selection_async(buf, mode, opts, callbacks)
  opts = opts or {}
  callbacks = callbacks or {}
  local run_seq = exec_seq
  local entries = opts.entries
  if not entries then
    -- derive from the buffer; callers that precompute entries (runner's
    -- SELECT re-injection) pass them via opts.entries — both sides must
    -- agree on the batch or indicators/db stamps misalign
    if mode == "visual" then
      -- opts.range is captured by the visual keymap while the selection is live.
      -- When absent (tests / programmatic), fall back to the '< '>' marks.
      entries = parser.visual_entries(buf, opts.range)
    else
      local e = parser.cursor_entry(buf)
      entries = e and { e } or {}
    end
  end
  if #entries == 0 then
    guarded(run_seq, callbacks.on_error, "No command at cursor", "")()
    return nil
  end
  -- Context inheritance, symmetric with USE: a selection run spawns a fresh
  -- redis-exec connection (db 0), so the nearest SELECT above the selection
  -- is silently re-applied via opts.db (run_async prepends it and swallows
  -- its result — no phantom tab or indicator).
  if not opts.db and entries[1] and entries[1].start_line then
    local db = M._db_for(buf, entries[1].start_line)
    if db and db > 0 then
      opts = vim.tbl_extend("keep", opts, { db = db })
    end
  end
  if not opts.connection then
    -- fall back to the current context / the first USE in the file
    local url, name = M._connection_for(buf)
    if url then
      opts = vim.tbl_extend("keep", opts, { connection = url, connection_name = name })
    end
  end
  if not opts.connection then
    guarded(run_seq, callbacks.on_error,
      "No connection resolved — run :PosteRedisConnection or add a USE line", "")()
    return nil
  end
  return M.run_async(entries, opts, callbacks)
end

--- Best-effort connection lookup: explicit opts > state context > last USE
--- in the file > first redis connection in connections.toml.
--- @param buf number
--- @return string|nil, string|nil url, connection_name
function M._connection_for(buf)
  local connections = require("poste-redis.connections")
  if redis_state.current_url then
    return redis_state.current_url, redis_state.context.connection
  end
  local entries = parser.buffer_entries(buf)
  for i = #entries, 1, -1 do
    if entries[i].kind == "use" and entries[i].connection then
      local url = connections.resolve(entries[i].connection)
      if url then
        connections.apply_connection(entries[i].connection, url)
        return url, entries[i].connection
      end
    end
  end
  return nil, nil
end

--- The db a statement at `before_line` (1-based) would run on: the nearest
--- SELECT above it within the current USE section. Single-statement runs
--- spawn a fresh redis-exec connection (db 0), so the file's own SELECT is
--- the only thing that can rebind it — the runner re-injects it.
--- @param buf number
--- @param before_line number  1-based line the scan stops at (exclusive)
--- @return number|nil db, number|nil line_1  1-based line of that SELECT
function M._db_for(buf, before_line)
  local entries = parser.buffer_entries(buf)
  local last_use_line = 0
  for _, e in ipairs(entries) do
    if before_line and e.start_line and e.start_line >= before_line then break end
    if e.kind == "use" and e.start_line then last_use_line = e.start_line end
  end
  local db, db_line
  for _, e in ipairs(entries) do
    if before_line and e.start_line and e.start_line >= before_line then break end
    if e.kind == "command" and e.start_line and e.start_line > last_use_line then
      local args = parser.entry_args(e)
      if args[1] == "SELECT" and tonumber(args[2]) then
        db = tonumber(args[2])
        db_line = e.start_line
      end
    end
  end
  return db, db_line
end

M._test = {
  decode_line = decode_line,
  guarded = guarded,
  seq_of = M.seq_of,
  is_busy = M.is_busy,
  cancel = M.cancel,
  _db_for = M._db_for,
}

return M
