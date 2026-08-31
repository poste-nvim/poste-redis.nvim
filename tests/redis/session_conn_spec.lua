--- session_conn spec — persistent redis session transport (M2 first item).
--- The `poste redis-session` process is stubbed: vim.fn.jobstart is replaced
--- with an in-memory fake job so specs never touch a real redis (Lua-side
--- stub development per EXECUTION-PLAN §10 / requirements §10 risk table).
local cli = require("poste.cli")
local session_conn = require("poste-redis.session_conn")

local URL = "redis://127.0.0.1:16379/0"

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

  it("increments seq per request and pairs responses to their request", function()
    local session = session_conn.get(URL)
    local responses = {}
    session_conn.execute(URL, { "GET", "a" }, {
      on_response = function(ev) responses[#responses + 1] = ev end,
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

  it("handles stdout split across chunks without a trailing newline", function()
    local session = session_conn.get(URL)
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
end)
