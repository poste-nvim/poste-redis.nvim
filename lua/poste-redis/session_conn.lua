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
--   seq         = number,
--   pending     = { [seq] = { on_response = fn, on_error = fn } },
--   buffer      = string,   -- partial stdout line buffer
--   alive       = boolean,
--   created_at  = number,   -- os.time()
--   last_active = number,   -- os.time()
-- }
local pool = {}

local function log(level, msg)
  vim.notify("PosteRedis session: " .. msg,
    level == "ERROR" and vim.log.levels.ERROR or vim.log.levels.DEBUG,
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
          if l ~= "" then log("WARN", "stderr: " .. l) end
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
--- @param opts table|nil { max_items, max_bytes } passed at process start
--- @return table|nil session
function M.get(conn_url, bufnr, opts)
  local session = pool[conn_url]
  if not session or not session.alive then
    session = start(conn_url, opts)
    if not session then return nil end
  end
  if bufnr then session.bufs[bufnr] = true end
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
---   - db: number|nil — if set and the session is not already on that db, a
---     SELECT is sent first so the command runs in the right database (the
---     long-lived connection keeps SELECT state, P1-5)
--- @return string "dispatched" | "start_failed" | "not_running"
function M.execute(conn_url, command, callbacks, bufnr, opts)
  callbacks = callbacks or {}
  opts = opts or {}
  local session = M.get(conn_url, bufnr, opts)
  if not session then
    return "start_failed"
  end
  if not session.alive then
    return "not_running"
  end

  -- Track + steer SELECT state on the shared connection. The first request
  -- carries the db; later ones switch only when the db actually changes.
  local db = opts.db
  if db ~= nil and session.db ~= db then
    session.db = db
    -- Fire-and-forget SELECT; errors surface via the real command's error.
    local sel_payload = vim.json.encode({ seq = 0, command = { "SELECT", tostring(db) } }) .. "\n"
    pcall(vim.fn.chansend, session.job_id, sel_payload)
  end

  session.seq = session.seq + 1
  session.last_active = os.time()
  local seq = session.seq
  session.pending[seq] = {
    on_response = callbacks.on_response,
    on_error = callbacks.on_error,
  }
  local payload = vim.json.encode({ seq = seq, command = command }) .. "\n"
  local sent = vim.fn.chansend(session.job_id, payload)
  if sent <= 0 then
    session.pending[seq] = nil
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

--- Remove a buffer from all sessions; close sessions with no remaining buffers.
--- @param bufnr number
function M.cleanup_buf(bufnr)
  for conn_url, session in pairs(pool) do
    session.bufs[bufnr] = nil
    if not next(session.bufs) then
      M.stop(conn_url)
    end
  end
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
}

return M
