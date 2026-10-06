--- session_conn spec — persistent redis session transport (M2 first item).
--- The `poste redis-session` process is stubbed: vim.fn.jobstart is replaced
--- with an in-memory fake job so specs never touch a real redis (Lua-side
--- stub development per EXECUTION-PLAN §10 / requirements §10 risk table).
local cli = require("poste-redis.cli")
local session_conn = require("poste-redis.session_conn")

local URL = "redis://127.0.0.1:16379/0"
local URL2 = "redis://127.0.0.1:16380/0"

describe("poste-redis session_conn", function()
  local orig_jobstart
  local orig_chansend
  local orig_jobwait
  local orig_binary
  local fake_job
  local next_job_id

  --- Install a fake jobstart that captures the session and lets the test
  --- drive its on_stdout/on_exit callbacks directly.
  local function stub_jobstart()
    fake_job = {
      id = next_job_id,
      cmd = nil,
      opts = nil,
      chansend = {},
      stdin_closed = false,
    }
    orig_jobstart = vim.fn.jobstart
    orig_chansend = vim.fn.chansend
    orig_jobwait = vim.fn.jobwait
    orig_binary = cli.binary
    vim.fn.jobstart = function(cmd, opts)
      fake_job.cmd = cmd
      fake_job.opts = opts
      return fake_job.id
    end
    vim.fn.chansend = function(id, payload)
      fake_job.chansend[#fake_job.chansend + 1] = payload
      return #payload
    end
    vim.fn.jobwait = function() return { -1 } end
    cli.binary = function() return "/tmp/poste-redis-fake-binary" end
  end

  local function restore_stubs()
    vim.fn.jobstart = orig_jobstart
    vim.fn.chansend = orig_chansend
    vim.fn.jobwait = orig_jobwait
    cli.binary = orig_binary
  end

  local function emit(session, lines)
    for _, l in ipairs(lines) do
      fake_job.opts.on_stdout(fake_job.id, { l })
    end
  end

  before_each(function()
    next_job_id = 9000
    session_conn.stop_all()
    stub_jobstart()
  end)

  after_each(function()
    session_conn.stop_all()
    restore_stubs()
  end)

  it("starts redis-session with the connection URL and max limits", function()
    local session = session_conn.get(URL, nil, { max_items = 7, max_bytes = 1024 })
    assert.is_not_nil(session)
    assert.equals("/tmp/poste-redis-fake-binary", fake_job.cmd[1])
    assert.equals("redis-session", fake_job.cmd[2])
    assert.equals("--connection", fake_job.cmd[3])
    assert.equals(URL, fake_job.cmd[4])
    assert.equals("--max-items", fake_job.cmd[5])
    assert.equals("7", fake_job.cmd[6])
    assert.equals("--max-bytes", fake_job.cmd[7])
    assert.equals("1024", fake_job.cmd[8])
  end)

  it("reuses one session per connection URL", function()
    local s1 = session_conn.get(URL)
    local s2 = session_conn.get(URL)
    assert.is_not_nil(s1)
    assert.equals(s1, s2)
    assert.equals(1, vim.fn.jobstart ~= orig_jobstart and 1 or 0) -- no new job started
  end)

  it("dispatches a {seq, command} request and routes the result event", function()
    local session = session_conn.get(URL)
    local responses, errs = {}, {}
    local status = session_conn.execute(URL, { "GET", "user:42" }, {
      on_response = function(ev) responses[#responses + 1] = ev end,
      on_error = function(msg) errs[#errs + 1] = msg end,
    })
    assert.equals("dispatched", status)
    assert.equals(1, #fake_job.chansend)
    local payload = vim.json.decode(fake_job.chansend[1])
    assert.equals(1, payload.seq)
    assert.same({ "GET", "user:42" }, payload.command)

    emit(session, { vim.json.encode({
      type = "result", seq = 1, command = "GET user:42", status = "\"Alice\"",
      latency_ms = 2, value = { type = "string", value = "Alice" },
    }) })
    assert.equals(1, #responses)
    assert.equals("Alice", responses[1].value.value)
    assert.equals(0, #errs)
  end)

  it("routes status=error events to on_error with the error text", function()
    local session = session_conn.get(URL)
    local errs = {}
    session_conn.execute(URL, { "FLUSHALL" }, {
      on_error = function(msg) errs[#errs + 1] = msg end,
    })
    emit(session, { vim.json.encode({
      type = "result", seq = 1, command = "FLUSHALL", status = "error",
      latency_ms = 1, error = "NOPERM ...",
    }) })
    assert.equals(1, #errs)
    assert.match("NOPERM", errs[1])
  end)

  it("survives a chansend THROW on a dead channel (command path)", function()
    -- chansend does not return -1 on a dead channel, it RAISES ("Can't send
    -- data to closed stream" / E900): the process can die between execute()'s
    -- alive check and the write. The command path used to call chansend
    -- unguarded, so the throw skipped the pending cleanup and the caller's
    -- on_error — a scan loop left its nodes loading forever.
    session_conn.get(URL)
    vim.fn.chansend = function() error("Can't send data to closed stream") end
    local errs = {}
    local status = session_conn.execute(URL, { "GET", "k" }, {
      on_response = function() error("on_response must not fire") end,
      on_error = function(msg) errs[#errs + 1] = msg end,
    })
    assert.equals("not_running", status)
    assert.equals(1, #errs)
    assert.match("chansend failed", errs[1])
    -- the request's pending entry must be gone, or the stall watchdog would
    -- later restart a session for a request that was already failed
    local session = session_conn._test.pool[URL]
    assert.equals(0, vim.tbl_count(session.pending))
  end)

  it("survives a chansend THROW on a dead channel (SELECT path)", function()
    session_conn.get(URL)
    vim.fn.chansend = function() error("Can't send data to closed stream") end
    local errs = {}
    local status = session_conn.execute(URL, { "GET", "k" }, {
      on_error = function(msg) errs[#errs + 1] = msg end,
    }, nil, { db = 2 })
    assert.equals("not_running", status)
    assert.equals(1, #errs)
    assert.match("SELECT", errs[1])
    -- the db write is undone so the next execute re-issues the SELECT
    local session = session_conn._test.pool[URL]
    assert.is_nil(session.db)
    assert.equals(0, vim.tbl_count(session.pending))
  end)

  it("increments seq per request and pairs responses to their request", function()
    local session = session_conn.get(URL)
    local responses = {}
    session_conn.execute(URL, { "GET", "a" }, {      on_response = function(ev) responses[#responses + 1] = ev end,
    })
    session_conn.execute(URL, { "GET", "b" }, {
      on_response = function(ev) responses[#responses + 1] = ev end,
    })
    assert.equals(2, #fake_job.chansend)
    assert.equals(1, vim.json.decode(fake_job.chansend[1]).seq)
    assert.equals(2, vim.json.decode(fake_job.chansend[2]).seq)

    -- out-of-order replies still land on the right callbacks (seq-keyed)
    emit(session, { vim.json.encode({
      type = "result", seq = 2, command = "GET b", status = "b", latency_ms = 1,
      value = { type = "string", value = "b" },
    }) })
    emit(session, { vim.json.encode({
      type = "result", seq = 1, command = "GET a", status = "a", latency_ms = 1,
      value = { type = "string", value = "a" },
    }) })
    assert.equals(2, #responses)
    assert.equals("b", responses[1].value.value)
    assert.equals("a", responses[2].value.value)
  end)

  it("prepends a tracked SELECT when opts.db differs from the session db", function()
    local session = session_conn.get(URL)
    local responses = {}
    session_conn.execute(URL, { "GET", "k" }, {
      on_response = function(ev) responses[#responses + 1] = ev end,
    }, nil, { db = 2 })
    -- first chansend is the SELECT (seq 1), second is the real command (seq 2)
    assert.equals(2, #fake_job.chansend)
    local sel = vim.json.decode(fake_job.chansend[1])
    assert.equals(1, sel.seq)
    assert.same({ "SELECT", "2" }, sel.command)
    local cmd = vim.json.decode(fake_job.chansend[2])
    assert.equals(2, cmd.seq)
    assert.same({ "GET", "k" }, cmd.command)

    -- same db again: no SELECT, just the command
    session_conn.execute(URL, { "GET", "k2" }, {
      on_response = function() end,
    }, nil, { db = 2 })
    assert.equals(3, #fake_job.chansend)
    assert.equals(3, vim.json.decode(fake_job.chansend[3]).seq)

    -- db switch: SELECT again
    session_conn.execute(URL, { "GET", "k3" }, {
      on_response = function() end,
    }, nil, { db = 5 })
    assert.equals(5, #fake_job.chansend)
    assert.same({ "SELECT", "5" }, vim.json.decode(fake_job.chansend[4]).command)

    -- the SELECT reply routes to its own pending entry (success: no-op) and
    -- never lands on the command's callbacks
    emit(session, { vim.json.encode({
      type = "result", seq = 1, command = "SELECT 2", status = "OK", latency_ms = 1,
      value = { type = "string", value = "OK" },
    }) })
    assert.equals(0, #responses)
  end)

  it("a chansend-failed SELECT fails the request without sending the command", function()
    -- The SELECT send used to be unchecked (pcall, result ignored): a dead
    -- channel left its pending entry unanswered, which the stall watchdog later "recovered" by restarting a possibly healthy
    -- session, and the command behind it ran unsteered on the current db.
    local session = session_conn.get(URL)
    local errs = {}
    vim.fn.chansend = function(id, payload)
      if payload and payload:find('"SELECT"') then return 0 end  -- dead channel
      fake_job.chansend[#fake_job.chansend + 1] = payload
      return #payload
    end
    local ret = session_conn.execute(URL, { "GET", "k" }, {
      on_response = function() assert.fail("command must not run") end,
      on_error = function(msg) errs[#errs + 1] = msg end,
    }, nil, { db = 3 })
    assert.equals("not_running", ret)
    assert.equals(1, #errs)
    assert.match("chansend failed", errs[1])
    -- the command was never sent, the SELECT pending entry is gone and the
    -- db bookkeeping reverted (the next execute re-issues the SELECT)
    assert.equals(0, #fake_job.chansend)
    assert.is_nil(session.pending[1])
    assert.is_nil(session.db)
  end)

  it("a failed SELECT errors the pipelined command and reverts the session db", function()    -- Regression: the SELECT was fire-and-forget (seq 0, no pending entry)
    -- while session.db was already updated — a failed SELECT (db out of
    -- range) left every later request silently running on the OLD db while
    -- the UI claimed the requested one.
    local session = session_conn.get(URL)
    local errs, responses = {}, {}
    session_conn.execute(URL, { "GET", "k" }, {
      on_response = function(ev) responses[#responses + 1] = ev end,
      on_error = function(msg) errs[#errs + 1] = msg end,
    }, nil, { db = 99 })
    -- SELECT (seq 1) fails; the command (seq 2) reply arrives anyway —
    -- its pending entry was removed, so it must not report success
    emit(session, {
      vim.json.encode({ type = "result", seq = 1, command = "SELECT 99", status = "error",
        latency_ms = 1, error = "ERR DB index is out of range" }),
      vim.json.encode({ type = "result", seq = 2, command = "GET k", status = "OK", latency_ms = 1,
        value = { type = "string", value = "wrong-db" } }),
    })
    assert.equals(1, #errs)
    assert.match("SELECT 99 failed", errs[1])
    assert.match("out of range", errs[1])
    assert.equals(0, #responses)

    -- the recorded db was reverted: the next execute re-issues the SELECT
    session_conn.execute(URL, { "GET", "k" }, {
      on_response = function() end,
    }, nil, { db = 99 })
    local sel = vim.json.decode(fake_job.chansend[#fake_job.chansend - 1])
    assert.same({ "SELECT", "99" }, sel.command)
  end)

  it("fails pending requests when the process exits and drops the session", function()
    local session = session_conn.get(URL)
    local errs = {}
    session_conn.execute(URL, { "GET", "k" }, {
      on_error = function(msg) errs[#errs + 1] = msg end,
    })
    fake_job.opts.on_exit(fake_job.id, 137)
    assert.equals(1, #errs)
    assert.match("exited", errs[1])

    -- pool entry removed: next get starts a fresh process
    local s2 = session_conn.get(URL)
    assert.is_not_nil(s2)
    assert.is_false(s2 == session)
    assert.is_true(s2.alive)
  end)

  it("keeps the session alive for the buffer that used it, closing when empty", function()
    local buf = vim.api.nvim_create_buf(false, true)
    session_conn.get(URL, buf)
    assert.equals(1, vim.tbl_count(session_conn.list()))
    session_conn.cleanup_buf(buf)
    assert.equals(0, vim.tbl_count(session_conn.list()))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("execute registers an owner tag; the session survives cleanup_buf of another buffer", function()
    local buf = vim.api.nvim_create_buf(false, true)
    session_conn.execute(URL, { "PING" }, nil, nil, { owner = "browser" })
    session_conn.get(URL, buf)
    -- the buffer is gone, but the browser still holds the session
    session_conn.cleanup_buf(buf)
    assert.equals(1, vim.tbl_count(session_conn.list()))
    session_conn.release("browser")
    assert.equals(0, vim.tbl_count(session_conn.list()))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("release stops solely-owned sessions but keeps ones another consumer holds", function()
    -- Regression: browser close ran cleanup_buf, and since execute callers
    -- never registered a buffer, EVERY pooled session (other connections
    -- included) was stopped. The browser now tags itself and releases.
    local buf = vim.api.nvim_create_buf(false, true)
    session_conn.get(URL2, buf)  -- result panel: buffer-registered session
    session_conn.execute(URL, { "PING" }, nil, nil, { owner = "browser" })
    assert.equals(2, vim.tbl_count(session_conn.list()))
    session_conn.release("browser")
    assert.equals(1, vim.tbl_count(session_conn.list()))
    assert.is_nil(session_conn.list()[URL], "browser-only session stops")
    assert.is_not_nil(session_conn.list()[URL2], "panel-held session survives")
    session_conn.cleanup_buf(buf)
    assert.equals(0, vim.tbl_count(session_conn.list()))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)



  it("handles stdout split across chunks without a trailing newline", function()
    session_conn.get(URL)
    local responses = {}
    session_conn.execute(URL, { "PING" }, {
      on_response = function(ev) responses[#responses + 1] = ev end,
    })
    local line = vim.json.encode({
      type = "result", seq = 1, command = "PING", status = "PONG", latency_ms = 1,
      value = { type = "string", value = "PONG" },
    })
    -- deliver in two chunks, no newline in either
    fake_job.opts.on_stdout(fake_job.id, { line:sub(1, 10) })
    assert.equals(0, #responses)
    fake_job.opts.on_stdout(fake_job.id, { line:sub(11) })
    assert.equals(1, #responses)
    assert.equals("PONG", responses[1].status)
  end)

  it("execute fires on_error when the session cannot start", function()
    cli.binary = function() return nil end  -- no binary: start() fails
    local errors = {}
    local status = session_conn.execute(URL, { "GET", "k" }, {
      on_error = function(msg) errors[#errors + 1] = msg end,
    })
    assert.equals("start_failed", status)
    assert.equals(1, #errors, "on_error must fire on start failure")
    assert.truthy(errors[1]:find("unavailable"))
  end)

  it("execute fires on_error when a dead session cannot be restarted", function()
    cli.binary = function() return nil end
    local errors = {}
    -- a dead pooled session makes get() try a restart; with no binary that
    -- fails and the caller's on_error must still fire
    session_conn._test.pool[URL] = {
      job_id = 1, conn_url = URL, bufs = {}, seq = 0, pending = {},
      buffer = "", alive = false, created_at = os.time(), last_active = os.time(),
    }
    local status = session_conn.execute(URL, { "GET", "k" }, {
      on_error = function(msg) errors[#errors + 1] = msg end,
    })
    assert.equals("start_failed", status)
    assert.equals(1, #errors, "on_error must fire when the session is dead")
  end)

  it("log levels map onto vim.log.levels (WARN is not DEBUG)", function()
    -- Regression: log() collapsed everything but "ERROR" to DEBUG, so the
    -- watchdog's "session stalled; restarting it" notice never surfaced.
    local levels = session_conn._test.log_levels
    assert.equals(vim.log.levels.ERROR, levels.ERROR)
    assert.equals(vim.log.levels.WARN, levels.WARN)
    assert.equals(vim.log.levels.DEBUG, levels.DEBUG)
    assert.is_true(levels.WARN ~= levels.DEBUG)
  end)

end)
