--- exec_run spec — transport contract + event dispatch + stale guard.
--- The poste binary is stubbed: poste.cli.run_async is replaced with an
--- in-process emitter so specs never touch a real redis (red line: Lua-side
--- stub development per EXECUTION-PLAN §10).
local cli = require("poste.cli")
local exec_run = require("poste-redis.exec_run")
local parser = require("poste-redis.parser")
local util = require("poste-redis.util")

describe("poste-redis exec_run", function()
  local orig_run_async
  local orig_run
  local emitted

  before_each(function()
    orig_run_async = cli.run_async
    orig_run = cli.run
    emitted = nil
  end)

  after_each(function()
    cli.run_async = orig_run_async
    cli.run = orig_run
  end)

  --- Install a stub that emits the given event lines, then on_exit(code).
  --- Mirrors cli.run_async's on_stdout(data)/on_exit(code) signatures.
  --- @param events string[]  raw NDJSON lines
  --- @param code number  exit code
  local function stub_emit(events, code)
    events = events or {}
    code = code or 0
    cli.run_async = function(_cmd, opts)
      emitted = { cmd = _cmd, stdin = opts and opts.stdin }
      vim.schedule(function()
        for _, ev in ipairs(events) do
          pcall(opts.on_stdout, { ev })
        end
        pcall(opts.on_stderr, {})
        pcall(opts.on_exit, code)
      end)
      return 4242
    end
  end

  local function wait_for(pending, timeout)
    return vim.wait(timeout or 500, function() return #pending > 0 end, 5)
  end

  local function entry(text)
    return parser.extract_entries(text .. "\n")[1]
  end

  it("emits the redis-exec command with stdin JSON payload", function()
    stub_emit({})
    local seq = exec_run.run_async({ entry("GET k") },
      { connection = "redis://127.0.0.1:6379/0" }, {})
    assert.is_not_nil(seq)
    assert.equals("redis-exec", emitted.cmd[1])
    local payload = vim.json.decode(emitted.stdin)
    assert.equals("redis://127.0.0.1:6379/0", payload.connection)
    assert.same({ { "GET", "k" } }, payload.commands)
    exec_run.cancel()
  end)

  it("passes --max-bytes from config and --max-items when given", function()
    stub_emit({})
    exec_run.run_async({ entry("GET k") },
      { connection = "redis://h:6379/0", max_items = 7, max_bytes = 1024 }, {})
    assert.equals("--max-items", emitted.cmd[2])
    assert.equals("7", emitted.cmd[3])
    assert.equals("--max-bytes", emitted.cmd[4])
    assert.equals("1024", emitted.cmd[5])
    exec_run.cancel()
  end)

  it("dispatches progress, result, summary in order", function()
    stub_emit({
      vim.json.encode({ type = "progress", index = 1, total = 2, command = "GET k" }),
      vim.json.encode({ type = "result", seq = 1, command = "GET k", status = "\"Alice\"", latency_ms = 2, value = { type = "string", value = "Alice" } }),
      vim.json.encode({ type = "result", seq = 2, command = "SET k v", status = "OK", latency_ms = 1, value = { type = "string", value = "OK" } }),
      vim.json.encode({ type = "summary", total = 2, failed = 0, elapsed_ms = 3 }),
    })
    local progress, results, summaries, done = {}, {}, {}, {}
    exec_run.run_async({ entry("GET k"), entry("SET k v") },
      { connection = "redis://h:6379/0" }, {
        on_progress = function(index, total, cmd) progress[#progress + 1] = { index, total, cmd } end,
        on_result = function(ev) results[#results + 1] = ev end,
        on_summary = function(ev) summaries[#summaries + 1] = ev end,
        on_done = function() done[#done + 1] = true end,
      })
    assert.equals(true, wait_for(progress))
    assert.equals(true, wait_for(results))
    assert.equals(true, wait_for(summaries))
    assert.equals(true, wait_for(done))
    assert.equals(1, #progress)
    assert.equals(2, #results)
    assert.equals(1, #summaries)
    assert.equals(2, summaries[1].total)
    assert.equals(0, summaries[1].failed)
    assert.equals("\"Alice\"", results[1].status)
    assert.equals(1, #done)
    exec_run.cancel()
  end)

  it("records command errors as results and keeps the batch going", function()
    stub_emit({
      vim.json.encode({ type = "result", seq = 1, command = "SET k v", status = "OK", latency_ms = 1, value = { type = "string", value = "OK" } }),
      vim.json.encode({ type = "result", seq = 2, command = "FLUSHALL", status = "error", latency_ms = 1, error = "NOPERM ..." }),
      vim.json.encode({ type = "summary", total = 2, failed = 1, elapsed_ms = 2 }),
    })
    local results, summaries = {}, {}
    exec_run.run_async({ entry("SET k v"), entry("FLUSHALL") },
      { connection = "redis://h:6379/0" }, {
        on_result = function(ev) results[#results + 1] = ev end,
        on_summary = function(ev) summaries[#summaries + 1] = ev end,
      })
    assert.equals(true, wait_for(results))
    assert.equals(true, wait_for(summaries))
    assert.equals(2, #results)
    assert.equals("error", results[2].status)
    assert.truthy(results[2].error)
    assert.equals(1, summaries[1].failed)
    exec_run.cancel()
  end)

  it("reports a process-level failure when no summary arrives", function()
    stub_emit({}, 1)
    local errs, done = {}, {}
    exec_run.run_async({ entry("GET k") },
      { connection = "redis://h:6379/0" }, {
        on_error = function(msg, stderr) errs[#errs + 1] = { msg, stderr } end,
        on_done = function() done[#done + 1] = true end,
      })
    assert.equals(true, wait_for(errs))
    assert.truthy(errs[1][1])
    assert.equals(true, wait_for(done))
    exec_run.cancel()
  end)

  it("rejects a non-redis connection URL", function()
    stub_emit({})
    local errs = {}
    exec_run.run_async({ entry("GET k") },
      { connection = "postgres://h/db" }, { on_error = function(m, _) errs[#errs + 1] = m end })
    assert.equals(true, wait_for(errs))
    assert.match("not a redis URL", errs[1])
    assert.is_nil(emitted)
    exec_run.cancel()
  end)

  it("errors when no connection was resolved", function()
    stub_emit({})
    local errs = {}
    exec_run.run_async({ entry("GET k") }, {}, { on_error = function(m) errs[#errs + 1] = m end })
    assert.equals(true, wait_for(errs))
    assert.match("No connection", errs[1])
    exec_run.cancel()
  end)

  it("drops stale callbacks after cancel and clears busy", function()
    stub_emit({
      vim.json.encode({ type = "result", seq = 1, command = "GET k", status = "OK", latency_ms = 1, value = { type = "string", value = "OK" } }),
      vim.json.encode({ type = "summary", total = 1, failed = 0, elapsed_ms = 1 }),
    })
    local results = {}
    exec_run.run_async({ entry("GET k") }, { connection = "redis://h:6379/0" }, {
      on_result = function(ev) results[#results + 1] = ev end,
    })
    exec_run.cancel()
    -- let the stubbed emitter drain; nothing should land
    vim.wait(200, function() return false end, 5)
    assert.equals(0, #results)
    assert.is_false(exec_run.is_busy())
  end)

  it("run_sync decodes the single result event", function()
    local out = table.concat({
      vim.json.encode({ type = "progress", index = 1, total = 1, command = "PING" }),
      vim.json.encode({ type = "result", seq = 1, command = "PING", status = "PONG", latency_ms = 1, value = { type = "string", value = "PONG" } }),
      vim.json.encode({ type = "summary", total = 1, failed = 0, elapsed_ms = 1 }),
    }, "\n")
    cli.run = function(_cmd, opts)
      emitted = { cmd = _cmd, stdin = opts and opts.stdin }
      return out, nil
    end
    local ev, err = exec_run.run_sync(entry("PING"), { connection = "redis://h:6379/0" })
    assert.is_nil(err)
    assert.equals("PONG", ev.status)
    assert.same({ "redis-exec", "--max-bytes" }, vim.list_slice(emitted.cmd, 1, 2))
  end)

  it("group_by_connection splits the file at USE and resolves URLs", function()
    local entries = parser.extract_entries("USE a\nGET 1\nUSE b\nSET k v\nGET 2\n")
    local groups = exec_run.group_by_connection(entries, function(name)
      return "redis://" .. name .. ":6379/0", nil
    end)
    assert.equals(2, #groups)
    assert.equals("redis://a:6379/0", groups[1].connection)
    assert.equals(1, #groups[1].entries)
    assert.equals("redis://b:6379/0", groups[2].connection)
    assert.equals(2, #groups[2].entries)
  end)

  it("group_by_connection reports commands without a USE", function()
    local entries = parser.extract_entries("GET 1\n")
    local groups = exec_run.group_by_connection(entries, function() return "redis://a:6379/0" end)
    assert.equals(1, #groups)
    assert.truthy(groups[1].error)
    assert.match("No connection", groups[1].error)
  end)

  it("group_by_connection falls back to the default URL when no USE", function()
    local entries = parser.extract_entries("GET 1\nGET 2\n")
    local groups = exec_run.group_by_connection(
      entries, function() return "redis://a:6379/0" end, "redis://default:6379/0")
    assert.equals(1, #groups)
    assert.is_nil(groups[1].error)
    assert.equals("redis://default:6379/0", groups[1].connection)
    assert.equals(2, #groups[1].entries)
  end)

  it("group_by_connection keeps USE overrides ahead of the default", function()
    local entries = parser.extract_entries("USE b\nGET 1\nGET 2\n")
    local groups = exec_run.group_by_connection(
      entries, function(name) return "redis://" .. name .. ":6379/0" end, "redis://default:6379/0")
    assert.equals(1, #groups)
    assert.equals("redis://b:6379/0", groups[1].connection)
    assert.equals(2, #groups[1].entries)
  end)

  it("run_file_async routes error groups through on_result", function()
    stub_emit({})
    local src = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(src, 0, -1, false, { "GET 1", "GET 2" })
    local results, done = {}, {}
    -- no default connection → both become error groups
    exec_run.run_file_async(src, {}, {
      on_result = function(ev) results[#results + 1] = ev end,
      on_done = function() done[#done + 1] = true end,
    })
    assert.equals(true, wait_for(results))
    assert.equals(2, #results)
    assert.equals("error", results[1].status)
    assert.truthy(results[1].error)
    assert.equals(true, wait_for(done))
    vim.api.nvim_buf_delete(src, { force = true })
  end)

  it("run_file_async executes against the default connection when no USE", function()
    stub_emit({})
    local src = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(src, 0, -1, false, { "GET 1", "GET 2" })
    local done = {}
    exec_run.run_file_async(src, { connection = "redis://default:6379/0" }, {
      on_done = function() done[#done + 1] = true end,
    })
    assert.equals(true, wait_for(done))
    assert.is_not_nil(emitted)
    assert.equals("redis-exec", emitted.cmd[1])
    local payload = vim.json.decode(emitted.stdin)
    assert.equals("redis://default:6379/0", payload.connection)
    assert.same({ { "GET", "1" }, { "GET", "2" } }, payload.commands)
    vim.api.nvim_buf_delete(src, { force = true })
  end)

  it("group_by_connection reports a bare USE", function()
    local entries = parser.extract_entries("USE\n")
    local groups = exec_run.group_by_connection(entries, function() return "redis://a:6379/0" end)
    assert.equals(1, #groups)
    assert.match("Bare USE", groups[1].error)
  end)

  it("redacts passwords from URLs", function()
    local r = util.redact_url("redis://:secret@127.0.0.1:6379/0")
    assert.is_nil(r:find("secret"))
    assert.truthy(r:find("***"))
  end)
end)
