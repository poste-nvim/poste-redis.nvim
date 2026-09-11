--- Persistent redis session connection management (M2, EXECUTION-PLAN §3.3).
---
--- Each session runs `poste redis-session --connection <url>` as a long-lived
--- process that keeps ONE redis connection open across requests. This lets
--- SELECT (db switch) and other per-connection state persist between separate
--- `<CR>` executions — the real payoff of the long-lived transport.
---
--- Wire protocol (crates/poste-cli/src/redis_session.rs):
---   stdin:  one JSON line per request  {"seq": 1, "command": ["GET", "k"]}
---   stdout: one JSON line per response {"type":"result","seq":1,"status":..,
---           "value":..} — the same shape as redis-exec result events, so the
---           Lua side renders sessions through the existing format/buffer path.
---   A failed command is status="error" + `error`; the process stays alive.
---
--- Sessions are pooled keyed by `connection_url` and shared across buffers
--- (poste-db session_conn.lua pattern, rebuilt for redis — no cross-satellite
--- require).

local redis_state = require("poste-redis.state")

local M = {}

-- The redis-session process caps array/map replies at --max-items (its own
-- default is 1000). SCAN COUNT 5000 would then have every page silently
-- truncated to 1000 keys while the cursor keeps advancing — keys lost. This
-- transport is redis-only and pagination is driven by Lua (SCAN cursor,
-- value view paging), so cap high; per-call opts.max_items still overrides.
local DEFAULT_MAX_ITEMS = 100000

-- pool[connection_url] = {
--   job_id      = number,
--   conn_url    = string,
--   bufs        = { [bufnr] = true },
--   owners      = { [string] = true },  -- logical owners (execute opts.owner)
--   seq         = number,
--   pending     = { [seq] = { on_response = fn, on_error = fn } },
--   buffer      = string,   -- partial stdout line buffer
--   alive       = boolean,
--   created_at  = number,   -- os.time()
--   last_active = number,   -- os.time()
-- }
local pool = {}

--- Level map: notify needs a vim.log.levels value; an unknown tag falls to
--- DEBUG (visible in :messages, never a popup). Callers pass "ERROR"/"WARN"/
--- "DEBUG" — WARN is reserved for one-off lifecycle events (a stalled session
--- restart); per-line stderr chatter logs at DEBUG so a chatty process cannot
--- spam notification popups (stderr text still reaches the user through the
--- on_error paths of every execute()).
local LOG_LEVELS = {
  ERROR = vim.log.levels.ERROR,
  WARN = vim.log.levels.WARN,
  DEBUG = vim.log.levels.DEBUG,
}

local function log(level, msg)
  vim.notify("PosteRedis session: " .. msg,
    LOG_LEVELS[level] or vim.log.levels.DEBUG,
    { title = redis_state.TITLE })
end

local function process_event(session, event)
  local cb = session.pending[event.seq]
  if cb then
    session.pending[event.seq] = nil
    local ok_cb, err = pcall(function()
      if event.status == "error" then
        if cb.on_error then cb.on_error(event.error or "unknown error", event) end
      else
        if cb.on_response then cb.on_response(event) end
      end
    end)
    if not ok_cb then
      log("ERROR", "callback error: " .. tostring(err))
    end
  end
end

local function process_line(session, line)
  local ok, event = pcall(vim.json.decode, line)
  if ok and type(event) == "table" and event.type == "result" then
    process_event(session, event)
  end
end

local function on_session_stdout(session, chunks)
  local combined = table.concat(chunks, "")
  session.buffer = session.buffer .. combined
  -- Each response is a single JSON line, but Neovim may deliver it with or
  -- without the trailing newline (or split across chunks).
  local pos = 1
  while true do
    local nl = session.buffer:find("\n", pos, true)
    if nl then
      local line = session.buffer:sub(pos, nl - 1)
      pos = nl + 1
      if line ~= "" then
        process_line(session, line)
      end
    else
      local remaining = session.buffer:sub(pos)
      if remaining ~= "" then
        local ok, event = pcall(vim.json.decode, remaining)
        if ok and type(event) == "table" and event.type == "result" then
          process_event(session, event)
          session.buffer = ""
        else
          session.buffer = remaining
        end
      else
        session.buffer = ""
      end
      break
    end
  end
end

local function on_session_exit(session, code)
  session.alive = false
  -- Fail all pending requests: the caller's busy state must never stick
  -- (family red line #4).
  for seq, cb in pairs(session.pending) do
    session.pending[seq] = nil
    if cb.on_error then
      pcall(cb.on_error, "redis session exited (code " .. code .. ")", nil)
    end
  end
  if pool[session.conn_url] == session then
    pool[session.conn_url] = nil
  end
end

--- Start a redis-session process. Returns the session or nil.
local function start(conn_url, opts)
  opts = opts or {}
  local binary = require("poste.cli").binary()
  if not binary then return nil end

  local now = os.time()
  local session = {
    job_id = nil,
    conn_url = conn_url,
    bufs = {},
    owners = {},
    seq = 0,
    pending = {},
    buffer = "",
    alive = true,
    created_at = now,
    last_active = now,
  }

  local cmd = { binary, "redis-session", "--connection", conn_url }
  local max_items = opts.max_items or DEFAULT_MAX_ITEMS
  if max_items then
    table.insert(cmd, "--max-items"); table.insert(cmd, tostring(max_items))
  end
  if opts.max_bytes then
    table.insert(cmd, "--max-bytes"); table.insert(cmd, tostring(opts.max_bytes))
  end

  -- on_stdout/on_exit already run on the main loop — never wrap them in
  -- vim.schedule (AGENTS.md pitfall: headless plenary does not pump it).
  local job_id = vim.fn.jobstart(cmd, {
    stdin = "pipe",
    stdout_buffered = false,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data and #data > 0 then on_session_stdout(session, data) end
    end,
    on_stderr = function(_, data)
      if data then
        for _, l in ipairs(data) do
          if l ~= "" then log("DEBUG", "stderr: " .. l) end
        end
      end
    end,
    on_exit = function(_, code)
      on_session_exit(session, code)
    end,
  })

  if job_id <= 0 then return nil end
  session.job_id = job_id
  pool[conn_url] = session
  return session
end

--- Get the session for a connection_url, starting one if needed.
--- @param conn_url string
--- @param bufnr number|nil buffer that will use this session
--- @param opts table|nil { max_items, max_bytes, owner } passed at process start
--- @return table|nil session
function M.get(conn_url, bufnr, opts)
  local session = pool[conn_url]
  if not session or not session.alive then
    session = start(conn_url, opts)
    if not session then return nil end
  end
  if bufnr then session.bufs[bufnr] = true end
  if opts and opts.owner then session.owners[opts.owner] = true end
  return session
end

--- Send a redis command to the session, executing it on the persistent
--- connection. Starts a session if none exists.
--- @param conn_url string
--- @param command string[] pre-tokenized command, e.g. {"GET", "user:42"}
--- @param callbacks table { on_response = fn(event), on_error = fn(msg, event?) }
--- @param bufnr number|nil
--- @param opts table|nil
---   - max_items, max_bytes: process-level limits (start only)
---   - owner: string|nil — tag this session as in use by a logical owner
---     (e.g. "browser"). Owners are released with M.release; a session an
---     owner still holds survives cleanup_buf of unrelated buffers.
---   - db: number|nil — if set and the session is not already on that db, a
---     SELECT is sent first so the command runs in the right database (the
---     long-lived connection keeps SELECT state, P1-5). A failed SELECT
---     errors the request (the command behind it would run on the old db)
---     and the next execute re-issues the SELECT.
--- @return string "dispatched" | "start_failed" | "not_running"
function M.execute(conn_url, command, callbacks, bufnr, opts)
  callbacks = callbacks or {}
  opts = opts or {}
  local session = M.get(conn_url, bufnr, opts)
  if not session then
    -- the caller's error path must fire even when no process could start
    -- (missing binary): scan loops otherwise leave nodes loading forever
    if callbacks.on_error then
      pcall(callbacks.on_error, "redis session unavailable (start failed)", nil)
    end
    return "start_failed"
  end
  if not session.alive then
    if callbacks.on_error then
      pcall(callbacks.on_error, "redis session is not running", nil)
    end
    return "not_running"
  end

  -- Track + steer SELECT state on the shared connection. The first request
  -- carries the db; later ones switch only when the db actually changes.
  -- The SELECT gets its own seq + pending entry: recording session.db BEFORE
  -- the reply is safe only while the reply is tracked — a failed SELECT
  -- (e.g. a db index out of range) leaves the connection on the old db, and
  -- the command already pipelined behind it would run THERE while the UI
  -- claims opts.db (silent wrong-db reads/writes).
  local db = opts.db
  local cmd_seq  -- assigned after the SELECT seq below; read by its handler
  if db ~= nil and session.db ~= db then
    local prev_db = session.db
    session.db = db
    session.seq = session.seq + 1
    local sel_seq = session.seq
    session.pending[sel_seq] = {
      on_response = function() end,  -- SELECT OK: nothing to do
      on_error = function(msg, event)
        -- revert so the next execute re-issues the SELECT, and fail the
        -- command pipelined behind it (its own reply, if any, ran on the
        -- wrong db and must not surface as success). A newer execute may
        -- have switched elsewhere already — only undo our own write.
        if session.db == db then session.db = prev_db end
        local cmd_cb = cmd_seq and session.pending[cmd_seq] or nil
        if cmd_seq then session.pending[cmd_seq] = nil end
        if cmd_cb and cmd_cb.on_error then
          cmd_cb.on_error("SELECT " .. tostring(db) .. " failed: " .. tostring(msg), event)
        end
      end,
      at = os.time(),
    }
    local sel_payload = vim.json.encode({ seq = sel_seq, command = { "SELECT", tostring(db) } }) .. "\n"
    pcall(vim.fn.chansend, session.job_id, sel_payload)
  end

  session.seq = session.seq + 1
  cmd_seq = session.seq
  session.last_active = os.time()
  session.pending[cmd_seq] = {
    on_response = callbacks.on_response,
    on_error = callbacks.on_error,
    at = os.time(),
  }
  local payload = vim.json.encode({ seq = cmd_seq, command = command }) .. "\n"
  local sent = vim.fn.chansend(session.job_id, payload)
  if sent <= 0 then
    session.pending[cmd_seq] = nil
    if callbacks.on_error then callbacks.on_error("redis session chansend failed", nil) end
    return "not_running"
  end
  return "dispatched"
end

--- Close the session for a connection_url.
--- @param conn_url string
function M.stop(conn_url)
  local session = pool[conn_url]
  if not session then return end
  session.alive = false
  pool[conn_url] = nil
  if session.job_id and vim.fn.jobwait({ session.job_id }, 0)[1] == -1 then
    pcall(vim.fn.chansend, session.job_id, "")
    pcall(vim.fn.chanclose, session.job_id, "stdin")
  end
end

--- Close all sessions.
function M.stop_all()
  for conn_url in pairs(pool) do
    M.stop(conn_url)
  end
end

--- Drop a logical owner (an execute(opts.owner) tag) from every pooled
--- session and stop the sessions nothing else still holds. This is what
--- makes cleanup_buf precise: closing one consumer (the browser) no longer
--- stops sessions other consumers registered buffers on.
--- @param owner string
function M.release(owner)
  for conn_url, session in pairs(pool) do
    session.owners[owner] = nil
    if not next(session.bufs) and not next(session.owners) then
      M.stop(conn_url)
    end
  end
end

--- Remove a buffer from all sessions; close sessions with no remaining buffers
--- and no remaining owners.
--- @param bufnr number
function M.cleanup_buf(bufnr)
  for conn_url, session in pairs(pool) do
    session.bufs[bufnr] = nil
    if not next(session.bufs) and not next(session.owners) then
      M.stop(conn_url)
    end
  end
end

-- A stalled session (dead TCP connection under the Rust driver, or a
-- channel whose stdout the event loop stopped reading) used to wedge the
-- browser forever: every later request queued behind the stall with no
-- error and no recovery. The watchdog fails requests that have been
-- pending too long and restarts the session process; the next execute
-- spawns a fresh one and the browser keeps working.
local STALL_LIMIT = 10  -- seconds without a response before restarting

local watchdog = assert(vim.loop.new_timer())
watchdog:start(2000, 2000, vim.schedule_wrap(function()
  local now = os.time()
  for conn_url, s in pairs(pool) do
    local stalled = false
    for _, cb in pairs(s.pending) do
      if cb.at and now - cb.at >= STALL_LIMIT then
        stalled = true
        break
      end
    end
    if stalled then
      log("WARN", "session stalled (no response for " .. STALL_LIMIT .. "s); restarting it")
      local job = s.job_id
      s.alive = false
      pool[conn_url] = nil
      for _, cb in pairs(s.pending) do
        if cb.on_error then
          pcall(cb.on_error, "redis session stalled; it was restarted", nil)
        end
      end
      s.pending = {}
      if job then pcall(vim.fn.jobstop, job) end
    end
  end
end))

--- Total requests awaiting a response, across all pooled sessions. The
--- browser's render flusher uses this to keep buffer mutations out of the
--- response stream (see browser/async.lua).
--- @return number
function M.in_flight()
  local n = 0
  for _, s in pairs(pool) do
    if s.alive then
      for _ in pairs(s.pending) do n = n + 1 end
    end
  end
  return n
end

--- List active sessions (debugging / health).
--- @return { [conn_url] = { job_id, created_at, last_active } }
function M.list()
  local out = {}
  for conn_url, session in pairs(pool) do
    out[conn_url] = {
      job_id = session.job_id,
      created_at = session.created_at,
      last_active = session.last_active,
    }
  end
  return out
end

M._test = {
  process_line = process_line,
  process_event = process_event,
  start = start,
  pool = pool,
  log_levels = LOG_LEVELS,
}

return M
