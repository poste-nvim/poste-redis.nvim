--- exec_run spec — transport contract + event dispatch + stale guard.
--- The poste binary is stubbed: poste.cli.run_async is replaced with an
--- in-process emitter so specs never touch a real redis (red line: Lua-side
--- stub development per EXECUTION-PLAN §10).
local cli = require("poste-redis.cli")
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
    cli.run_async = function(cmd, opts)
      emitted = { cmd = cmd, stdin = opts and opts.stdin }
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

  it("reports a jobstart failure — on_error fires before the seq is invalidated", function()
    -- regression: the start-failure branch bumped exec_seq before firing the
    -- guarded on_error, and the guard then dropped it — a failed jobstart
    -- never notified anyone and the dispatch chain stranded on its group.
    cli.run_async = function(_cmd, _opts) return -1 end
    local errs, done = {}, {}
    exec_run.run_async({ entry("GET k") },
      { connection = "redis://h:6379/0" }, {
        on_error = function(msg, _) errs[#errs + 1] = msg end,
        on_done = function() done[#done + 1] = true end,
      })
    assert.equals(1, #errs)  -- delivered synchronously, not dropped
    assert.match("Failed to start redis%-exec", errs[1])
    assert.equals(1, #done)  -- caller unwinds (spinners clear / chain continues)
    assert.equals(false, exec_run.is_busy())
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
    cli.run = function(cmd, opts)
      emitted = { cmd = cmd, stdin = opts and opts.stdin }
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

  it("run_file_async keeps each USE group's connection even with a default URL", function()
    -- Regression: dispatch_group merged the group connection with "keep", so
    -- opts.connection (the pre-USE default) overrode every USE group and the
    -- whole file ran against the default connection.
    local payloads = {}
    local saved_run_async = cli.run_async
    cli.run_async = function(cmd, opts)
      payloads[#payloads + 1] = vim.json.decode(opts.stdin).connection
      vim.schedule(function()
        pcall(opts.on_stdout, {
          vim.json.encode({ type = "result", seq = 1, command = "GET", status = "OK", latency_ms = 1 }),
          vim.json.encode({ type = "summary", total = 1, failed = 0, elapsed_ms = 1 }),
        })
        pcall(opts.on_exit, 0)
      end)
      return 4242
    end
    local src = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(src, 0, -1, false, { "GET pre", "USE a", "GET 1", "USE b", "GET 2" })
    local done = {}
    exec_run.run_file_async(src, {
      connection = "redis://default:6379/0",
      resolve_url = function(name) return "redis://" .. name .. ":6379/0", nil end,
    }, {
      on_done = function() done[#done + 1] = true end,
    })
    assert.equals(true, wait_for(done))
    assert.same({
      "redis://default:6379/0",  -- commands before any USE
      "redis://a:6379/0",        -- USE a group keeps its own URL
      "redis://b:6379/0",        -- USE b group keeps its own URL
    }, payloads)
    cli.run_async = saved_run_async
    vim.api.nvim_buf_delete(src, { force = true })
    exec_run.cancel()
  end)

  it("run_file_async skips a trailing empty USE group and still fires on_done", function()
    -- Regression: a `USE name` with no command under it (file end, or only
    -- comments after) dispatched a zero-command batch. run_async refuses
    -- those with "Nothing to execute" and never calls on_done, so the
    -- dispatch chain stranded — the runner's "running" indicators stayed
    -- forever and no panel rendered.
    stub_emit({})
    local src = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(src, 0, -1, false, { "USE a", "GET 1", "USE b" })
    local results, done = {}, {}
    exec_run.run_file_async(src, {
      connection = "redis://default:6379/0",
      resolve_url = function(name) return "redis://" .. name .. ":6379/0", nil end,
    }, {
      on_result = function(ev) results[#results + 1] = ev end,
      on_done = function() done[#done + 1] = true end,
    })
    assert.equals(true, wait_for(done))
    assert.equals(1, #done)
    -- only the a-group batch ran; the empty b group dispatched nothing
    assert.is_not_nil(emitted)
    local payload = vim.json.decode(emitted.stdin)
    assert.equals("redis://a:6379/0", payload.connection)
    assert.same({ { "GET", "1" } }, payload.commands)
    assert.equals(0, #results)
    vim.api.nvim_buf_delete(src, { force = true })
    exec_run.cancel()
  end)

  it("run_file_async completes on a file that is only a USE", function()
    stub_emit({})
    local src = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(src, 0, -1, false, { "USE a" })
    local done = {}
    exec_run.run_file_async(src, {
      connection = "redis://default:6379/0",
      resolve_url = function() return "redis://a:6379/0", nil end,
    }, {
      on_done = function() done[#done + 1] = true end,
    })
    assert.equals(true, wait_for(done))
    assert.is_nil(emitted)  -- nothing to run anywhere
    vim.api.nvim_buf_delete(src, { force = true })
    exec_run.cancel()
  end)

  it("run_file_async stamps each result with its source entry line across USE groups", function()
    -- The binary's `seq` restarts at 1 per batch; a caller mapping seq onto
    -- whole-file lines misplaces every group after the first. dispatch_group
    -- now stamps ev.src_line from the parser entry (1-based file line).
    local saved_run_async = cli.run_async
    cli.run_async = function(cmd, opts)
      vim.schedule(function()
        pcall(opts.on_stdout, {
          vim.json.encode({ type = "result", seq = 1, command = "GET", status = "OK", latency_ms = 1 }),
          vim.json.encode({ type = "summary", total = 1, failed = 0, elapsed_ms = 1 }),
        })
        pcall(opts.on_exit, 0)
      end)
      return 4242
    end
    local src = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(src, 0, -1, false, { "USE a", "GET one", "", "USE b", "GET two" })
    local src_lines = {}
    exec_run.run_file_async(src, {
      resolve_url = function(name) return "redis://" .. name .. ":6379/0", nil end,
    }, {
      on_result = function(ev) src_lines[#src_lines + 1] = ev.src_line end,
    })
    assert.truthy(vim.wait(1000, function() return #src_lines >= 2 end))
    -- "GET one" is file line 2, "GET two" is file line 5 — NOT seq 1 for both
    assert.same({ 2, 5 }, src_lines)
    cli.run_async = saved_run_async
    vim.api.nvim_buf_delete(src, { force = true })
    exec_run.cancel()
  end)

  it("dispatch walks consecutive error groups in a loop — flat stack on a pathological file", function()
    -- every bare USE becomes an error group; the old per-group recursion
    -- nested one frame per group (same shape the es preflight fix removed)
    stub_emit({})
    local lines = {}
    for i = 1, 3000 do lines[i] = "USE" end
    local src = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(src, 0, -1, false, lines)
    local results, done_depth = {}, nil
    exec_run.run_file_async(src, {}, {
      on_result = function(ev) results[#results + 1] = ev end,
      on_done = function()
        local level = 1
        while debug.getinfo(level, "") do level = level + 1 end
        done_depth = level
      end,
    })
    assert.equals(3000, #results)
    assert.is_true(done_depth < 100)
    vim.api.nvim_buf_delete(src, { force = true })
    exec_run.cancel()
  end)

  it("run_selection_async resolves connection from USE when opts omit it", function()
    stub_emit({})
    local connections = require("poste-redis.connections")
    local orig_resolve = connections.resolve_redis_url
    connections.resolve_redis_url = function(name)
      return "redis://" .. name .. ":6379/0", nil
    end
    local redis_state = require("poste-redis.state")
    redis_state.current_url = nil

    local src = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(src, 0, -1, false, { "USE srv", "GET k" })
    vim.api.nvim_set_current_buf(src)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    local errs = {}
    exec_run.run_selection_async(src, "cursor", {}, {
      on_error = function(m) errs[#errs + 1] = m end,
    })
    assert.truthy(emitted)
    local payload = vim.json.decode(emitted.stdin)
    assert.equals("redis://srv:6379/0", payload.connection)
    assert.same({ { "GET", "k" } }, payload.commands)
    assert.equals(0, #errs)
    connections.resolve_redis_url = orig_resolve
    redis_state.current_url = nil
    vim.api.nvim_buf_delete(src, { force = true })
    exec_run.cancel()
  end)

  it("run_selection_async inherits the NEAREST USE above, not the file's last", function()
    -- Regression: the fallback walked the file's LAST USE, so a cursor run
    -- inside the `USE a` section of `USE a / GET 1 / USE b / GET 2` executed
    -- against b — cross-connection, silently. It must mirror the winbar's
    -- section context (and stamp the group name onto the result label).
    stub_emit({
      vim.json.encode({ type = "result", seq = 1, command = "GET 1", status = "OK", latency_ms = 1 }),
      vim.json.encode({ type = "summary", total = 1, failed = 0, elapsed_ms = 1 }),
    })
    local connections = require("poste-redis.connections")
    local orig_resolve = connections.resolve_redis_url
    connections.resolve_redis_url = function(name)
      return "redis://" .. name .. ":6379/0", nil
    end
    local redis_state = require("poste-redis.state")
    redis_state.current_url = nil

    local src = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(src, 0, -1, false, { "USE a", "GET 1", "USE b", "GET 2" })
    vim.api.nvim_set_current_buf(src)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })  -- GET 1, inside the a section
    local results = {}
    exec_run.run_selection_async(src, "cursor", {}, {
      on_result = function(ev) results[#results + 1] = ev end,
    })
    assert.equals(true, wait_for(results))
    assert.equals(1, #results)
    local payload = vim.json.decode(emitted.stdin)
    assert.equals("redis://a:6379/0", payload.connection)
    assert.equals("a", results[1].connection_name)
    connections.resolve_redis_url = orig_resolve
    redis_state.current_url = nil
    vim.api.nvim_buf_delete(src, { force = true })
    exec_run.cancel()
  end)

  it("run_selection_async reports when no connection can be resolved", function()
    stub_emit({})
    local connections = require("poste-redis.connections")
    local orig_resolve = connections.resolve_redis_url
    connections.resolve_redis_url = function(_name) return nil, "boom" end
    local redis_state = require("poste-redis.state")
    redis_state.current_url = nil

    local src = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_lines(src, 0, -1, false, { "USE srv", "GET k" })
    vim.api.nvim_set_current_buf(src)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    local errs = {}
    exec_run.run_selection_async(src, "cursor", {}, {
      on_error = function(m) errs[#errs + 1] = m end,
    })
    assert.equals(1, #errs)
    assert.match("No connection", errs[1])
    -- the resolve error must ride along: "Invalid port for redis connection
    -- 'srv'" reads as a fixable config bug, while "no connection resolved"
    -- sends the user off to add a USE line that is already there
    assert.match("boom", errs[1])
    connections.resolve_redis_url = orig_resolve
    redis_state.current_url = nil
    vim.api.nvim_buf_delete(src, { force = true })
  end)

  it("run_selection_async visual mode honors the explicit range, not marks", function()
    stub_emit({})
    local src = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_lines(src, 0, -1, false, { "GET a", "GET b", "GET c", "GET d" })
    vim.api.nvim_set_current_buf(src)
    -- cursor is on line 4 and there are no live '< '>' marks; only the
    -- explicit range may select the batch
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    local errs = {}
    exec_run.run_selection_async(src, "visual", {
      connection = "redis://h:6379/0",
      range = { start_line = 2, end_line = 3 },
    }, {
      on_error = function(m) errs[#errs + 1] = m end,
    })
    assert.equals(0, #errs)
    assert.truthy(emitted)
    local payload = vim.json.decode(emitted.stdin)
    assert.same({ { "GET", "b" }, { "GET", "c" } }, payload.commands)
    vim.api.nvim_buf_delete(src, { force = true })
    exec_run.cancel()
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

  it("cursor runs inherit the file's SELECT silently (no phantom result)", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "USE a", "SELECT 3", "GET x" })
    stub_emit({
      vim.json.encode({ type = "result", seq = 1, command = "SELECT 3", status = "OK", latency_ms = 1, value = { type = "string", value = "OK" } }),
      vim.json.encode({ type = "result", seq = 2, command = "GET x", status = "\"v\"", latency_ms = 1, value = { type = "string", value = "v" } }),
    })
    local results, done = {}, {}
    local get = entry("GET x")
    get.start_line = 3
    exec_run.run_selection_async(buf, "cursor", {
      entries = { get },
      connection = "redis://h:6379/0",
    }, {
      on_result = function(ev) results[#results + 1] = ev end,
      on_done = function() done[#done + 1] = true end,
    })
    assert.equals(true, wait_for(done))
    -- the injected SELECT ran but its result is swallowed and seq renumbered
    assert.equals(1, #results)
    assert.equals("GET x", results[1].command)
    assert.equals(1, results[1].seq)
    assert.equals(3, results[1].db)
    local payload = vim.json.decode(emitted.stdin)
    assert.same({ "SELECT", "3" }, payload.commands[1])
    assert.same({ "GET", "x" }, payload.commands[2])
    exec_run.cancel()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("stamps each result with the db its command ran on (SELECT-aware)", function()
    stub_emit({
      vim.json.encode({ type = "result", seq = 1, command = "GET k", status = "\"v\"", latency_ms = 1, value = { type = "string", value = "v" } }),
      vim.json.encode({ type = "result", seq = 2, command = "SELECT 3", status = "OK", latency_ms = 1, value = { type = "string", value = "OK" } }),
      vim.json.encode({ type = "result", seq = 3, command = "GET k2", status = "\"w\"", latency_ms = 1, value = { type = "string", value = "w" } }),
    })
    local results, done = {}, {}
    exec_run.run_async({ entry("GET k"), entry("SELECT 3"), entry("GET k2") },
      { connection = "redis://h:6379/0" }, {
        on_result = function(ev) results[#results + 1] = ev end,
        on_done = function() done[#done + 1] = true end,
      })
    assert.equals(true, wait_for(done))
    -- every redis-exec process starts on db 0; a successful SELECT rebinds
    assert.equals(0, results[1].db)
    assert.equals(0, results[2].db)  -- the SELECT itself ran on db 0
    assert.equals(3, results[3].db)
    exec_run.cancel()
  end)

  it("keeps the db when a SELECT fails", function()
    stub_emit({
      vim.json.encode({ type = "result", seq = 1, command = "SELECT 99", status = "error", error = "ERR DB index is out of range", latency_ms = 1 }),
      vim.json.encode({ type = "result", seq = 2, command = "GET k", status = "nil", latency_ms = 1, value = { type = "nil", value = nil } }),
    })
    local results, done = {}, {}
    exec_run.run_async({ entry("SELECT 99"), entry("GET k") },
      { connection = "redis://h:6379/0" }, {
        on_result = function(ev) results[#results + 1] = ev end,
        on_done = function() done[#done + 1] = true end,
      })
    assert.equals(true, wait_for(done))
    assert.equals(0, results[1].db)
    assert.equals(0, results[2].db)
    exec_run.cancel()
  end)

  it("_db_for finds the nearest SELECT above a line, scoped to its USE section", function()
    local src = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(src, 0, -1, false, {
      "USE a", "SELECT 3", "GET x", "USE b", "GET y",
    })
    local db, line = exec_run._db_for(src, 3)
    assert.equals(3, db)
    assert.equals(2, line)
    -- USE b starts a new section: the old SELECT no longer applies
    assert.is_nil(exec_run._db_for(src, 5))
    -- before the SELECT there is nothing to inherit
    assert.is_nil(exec_run._db_for(src, 2))
    vim.api.nvim_buf_delete(src, { force = true })
  end)
end)

--- Regression: dispatch_group evaluated the stale guard at CALLBACK time
--- (`guarded(exec_seq, ...)` compared the seq with itself), so a canceled
--- run kept dispatching its remaining USE groups and rendering their results.
describe("poste-redis exec_run group chain", function()
  local entries_buf

  before_each(function()
    entries_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(entries_buf, 0, -1, false, { "USE a", "GET 1", "USE b", "GET 2" })
  end)

  after_each(function()
    vim.api.nvim_buf_delete(entries_buf, { force = true })
  end)

  local function run_file(callbacks)
    return exec_run.run_file_async(entries_buf, {
      connection = "redis://fallback",
      resolve_url = function() return "redis://resolved", nil end,
    }, callbacks)
  end

  it("cancel during on_group stops the remaining group chain", function()
    local orig_run_async = cli.run_async
    local dispatched = 0
    cli.run_async = function(_cmd, _opts)
      dispatched = dispatched + 1
      return 4242
    end
    local results, done_fired = {}, false
    local groups_seen = 0
    run_file({
      on_group = function()
        groups_seen = groups_seen + 1
        exec_run.cancel()  -- supersede while the chain is between groups
      end,
      on_result = function(ev) results[#results + 1] = ev end,
      on_done = function() done_fired = true end,
    })
    vim.wait(50)
    cli.run_async = orig_run_async
    assert.equals(0, dispatched, "no batch may run after the cancel")
    assert.equals(0, #results, "no results may render after the cancel")
    assert.is_false(done_fired, "the canceled run must not report done")
  end)

  it("a newer file run supersedes the previous run's pending results", function()
    local orig_run_async = cli.run_async
    cli.run_async = function(cmd, opts)
      -- complete synchronously with one result + summary
      vim.schedule(function()
        pcall(opts.on_stdout, {
          vim.json.encode({ type = "result", seq = 1, command = "GET", status = "OK", latency_ms = 1 }),
          vim.json.encode({ type = "summary", total = 1, failed = 0, elapsed_ms = 1 }),
        })
        pcall(opts.on_exit, 0)
      end)
      return 4242
    end
    local run1_results = {}
    local run1_done = false
    run_file({
      on_result = function(ev) run1_results[#run1_results + 1] = ev end,
      on_done = function() run1_done = true end,
    })
    -- supersede before the scheduled events land
    exec_run.cancel()
    vim.wait(50)
    cli.run_async = orig_run_async
    assert.equals(0, #run1_results, "superseded run's results must drop")
    assert.is_false(run1_done)
  end)
end)
