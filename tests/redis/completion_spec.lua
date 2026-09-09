--- completion spec — context detection + item assembly (P2-4).
--- The completion pipeline is transport-stubbed: session_conn.execute is
--- replaced so key-prefix candidates never touch a real redis.
local ctx = require("poste-redis.completion.ctx")
local data = require("poste-redis.completion.data")
local completion = require("poste-redis.completion.init")
local session_conn = require("poste-redis.session_conn")
local exec_run = require("poste-redis.exec_run")

describe("poste-redis completion ctx", function()
  it("detects a command position with a single token", function()
    local d = ctx.detect("GET")
    assert.equals("command", d.kind)
    assert.equals("GET", d.prefix)
  end)

  it("detects a command position with a partial command", function()
    local d = ctx.detect("ZAD")
    assert.equals("command", d.kind)
    assert.equals("ZAD", d.prefix)
  end)

  it("detects a command position case-insensitively", function()
    local d = ctx.detect("get")
    assert.equals("command", d.kind)
    assert.equals("get", d.prefix)
  end)

  it("detects an argument position on a trailing space (empty prefix)", function()
    -- accepting a command completion inserts "GET " with the trailing
    -- space; the menu must then offer keys, not the command table again
    local d = ctx.detect("GET ")
    assert.equals("key", d.kind)
    assert.equals("", d.prefix)
    assert.equals("GET", d.command)
    -- USE keeps its own completion kind
    local u = ctx.detect("USE ")
    assert.equals("connection", u.kind)
    assert.equals("", u.prefix)
  end)

  it("detects a key argument position with a prefix", function()
    local d = ctx.detect("GET user:")
    assert.equals("key", d.kind)
    assert.equals("user:", d.prefix)
    assert.equals("GET", d.command)
  end)

  it("detects a key argument after leading whitespace", function()
    local d = ctx.detect("  GET user:")
    assert.equals("key", d.kind)
    assert.equals("user:", d.prefix)
  end)

  it("detects a connection position after USE", function()
    local d = ctx.detect("USE my-red")
    assert.equals("connection", d.kind)
    assert.equals("my-red", d.prefix)
    assert.equals("USE", d.command)
  end)

  it("detects a connection position for a bare USE", function()
    local d = ctx.detect("USE ")
    assert.equals("connection", d.kind)
    assert.equals("", d.prefix)
  end)

  it("returns none for a comment line", function()
    assert.equals("none", ctx.detect("# a comment").kind)
    assert.equals("none", ctx.detect("-- a comment").kind)
  end)

  it("returns none for blank input", function()
    assert.equals("none", ctx.detect("").kind)
    assert.equals("none", ctx.detect("   ").kind)
  end)

  it("returns none inside a quoted string", function()
    assert.equals("none", ctx.detect('SET k "fo').kind)
  end)

  it("fuzzy-matches subsequence patterns", function()
    assert.is_true(ctx.fuzzy_match("GETSET", "gts"))
    assert.is_true(ctx.fuzzy_match("GETSET", ""))
    assert.is_false(ctx.fuzzy_match("GETSET", "xyz"))
  end)

  it("filters items by fuzzy prefix", function()
    local items = ctx.make_items({ "GET", "GETSET", "SET" }, 3, "command: ")
    local filtered = ctx.filter(items, "get")
    assert.equals(2, #filtered)
    local labels = {}
    for _, i in ipairs(filtered) do labels[#labels + 1] = i.label end
    assert.same({ "GET", "GETSET" }, labels)
  end)
end)

describe("poste-redis completion data", function()
  it("exposes the command table", function()
    assert.truthy(#data.COMMANDS >= 150)
    assert.truthy(vim.tbl_contains(data.COMMANDS, "GET"))
    assert.truthy(vim.tbl_contains(data.COMMANDS, "ZADD"))
    assert.truthy(vim.tbl_contains(data.COMMANDS, "XADD"))
    assert.truthy(vim.tbl_contains(data.COMMANDS, "FLUSHALL"))
  end)

  it("loads connection names from connections.toml (redis only)", function()
    local tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir, "p")
    vim.fn.writefile({
      "[my-redis]",
      'dialect = "redis"',
      'url = "redis://127.0.0.1:6379/0"',
      "",
      "[my-pg]",
      'dialect = "postgres"',
      'host = "pg"',
    }, tmpdir .. "/connections.toml")
    local conns = require("poste-redis.connections")
    conns._test.reset_caches()
    local orig_cwd = vim.fn.getcwd()
    vim.api.nvim_set_current_dir(tmpdir)

    data.clear_conn_names()
    local names = nil
    data.ensure_conn_names(function(n) names = n end)
    assert.equals(true, vim.wait(500, function() return names ~= nil end, 5))
    assert.same({ "my-redis" }, names)

    -- restore BEFORE cleanup: a spec that leaves the suite chdir'd into a
    -- dir it is about to delete poisons every later file (mail 09-08 lesson)
    vim.api.nvim_set_current_dir(orig_cwd)
    conns._test.reset_caches()
    data.clear_conn_names()
    pcall(vim.fn.delete, tmpdir, "rf")
  end)

  it("refreshes connection names when connections.toml changes mid-session", function()
    local tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir, "p")
    vim.fn.writefile({
      "[first]",
      'dialect = "redis"',
      'url = "redis://127.0.0.1:6379/0"',
    }, tmpdir .. "/connections.toml")
    local conns = require("poste-redis.connections")
    conns._test.reset_caches()
    local orig_cwd = vim.fn.getcwd()
    vim.api.nvim_set_current_dir(tmpdir)

    data.clear_conn_names()
    local names = nil
    data.ensure_conn_names(function(n) names = n end)
    assert.equals(true, vim.wait(500, function() return names ~= nil end, 5))
    assert.same({ "first" }, names)

    -- a second connection appears in the file (mtime forced forward so the
    -- change is visible regardless of filesystem timestamp granularity)
    local path = tmpdir .. "/connections.toml"
    vim.fn.writefile({
      "[first]",
      'dialect = "redis"',
      'url = "redis://127.0.0.1:6379/0"',
      "",
      "[second]",
      'dialect = "redis"',
      'url = "redis://127.0.0.1:6380/0"',
    }, path)
    vim.uv.fs_utime(path, os.time() + 10, os.time() + 10)

    local refreshed = nil
    data.ensure_conn_names(function(n) refreshed = n end)
    assert.equals(true, vim.wait(500, function() return refreshed ~= nil end, 5))
    assert.same({ "first", "second" }, refreshed)

    vim.api.nvim_set_current_dir(orig_cwd)
    conns._test.reset_caches()
    data.clear_conn_names()
    pcall(vim.fn.delete, tmpdir, "rf")
  end)

  it("returns no key candidates for an empty prefix", function()
    local results = nil
    data.ensure_key_candidates("redis://h:6379/0", "", 0, function(r) results = r end)
    assert.same({}, results)
  end)

  it("returns no key candidates without a connection", function()
    local results = nil
    data.ensure_key_candidates(nil, "user:", 0, function(r) results = r end)
    assert.same({}, results)
  end)

  it("fetches key candidates via SCAN MATCH and caches per prefix", function()
    local orig_execute = session_conn.execute
    local calls = {}
    data.clear_key_cache()
    session_conn.execute = function(_url, cmd, callbacks)
      table.insert(calls, cmd)
      assert.same("SCAN", cmd[1])
      assert.same("user:*", cmd[4])
      -- fake SCAN reply: keys live in ev.value.value (redis_executor shape)
      vim.schedule(function()
        callbacks.on_response({
          value = { value = { "user:1", "user:2", "other:9" } },
        })
      end)
    end

    local first, second = nil, nil
    data.ensure_key_candidates("redis://h:6379/0", "user:", 0, function(r) first = r end)
    assert.equals(true, vim.wait(500, function() return first ~= nil end, 5))
    -- second call hits the cache: no new SCAN
    data.ensure_key_candidates("redis://h:6379/0", "user:", 0, function(r) second = r end)
    assert.same({ "user:1", "user:2" }, first)
    assert.same(first, second)
    assert.equals(1, #calls)

    data.clear_key_cache()
    session_conn.execute = orig_execute
  end)

  it("a stale in-flight SCAN cannot answer a post-clear fetch", function()
    -- clear_key_cache drops an in-flight fetch's callbacks; a NEWER fetch
    -- for the same prefix may start right after, and the stale response
    -- must neither flush the new callbacks nor poison the fresh cache
    local orig_execute = session_conn.execute
    data.clear_key_cache()
    local pending_response = nil
    session_conn.execute = function(_url, cmd, callbacks)
      -- capture the FIRST fetch's response for later delivery
      if pending_response == nil then
        pending_response = function()
          callbacks.on_response({ value = { value = { "user:OLD" } } })
        end
        return "dispatched"
      end
      -- second fetch resolves immediately with fresh data
      vim.schedule(function()
        callbacks.on_response({ value = { value = { "user:NEW" } } })
      end)
      return "dispatched"
    end

    local first_result, second_result = nil, nil
    data.ensure_key_candidates("redis://h:6379/0", "user:", 0, function(r) first_result = r end)
    data.clear_key_cache()  -- mutation invalidates mid-flight
    data.ensure_key_candidates("redis://h:6379/0", "user:", 0, function(r) second_result = r end)

    pending_response()  -- the stale SCAN lands after the clear

    assert.is_true(vim.wait(500, function() return second_result ~= nil end, 5))
    assert.same({ "user:NEW" }, second_result, "new fetch must get fresh data")
    assert.is_nil(first_result, "the cleared fetch's callback stays dead")
    session_conn.execute = orig_execute
  end)

  it("handles a SCAN error by returning no candidates", function()
    local orig_execute = session_conn.execute
    data.clear_key_cache()
    session_conn.execute = function(_url, _cmd, callbacks)
      vim.schedule(function() callbacks.on_error("connection refused") end)
    end
    local results = nil
    data.ensure_key_candidates("redis://h:6379/0", "user:", 0, function(r) results = r end)
    assert.equals(true, vim.wait(500, function() return results ~= nil end, 5))
    assert.same({}, results)
    session_conn.execute = orig_execute
  end)
end)

describe("poste-redis completion orchestrator", function()
  local orig_exec_run_connection_for
  local orig_ensure_keys

  before_each(function()
    orig_exec_run_connection_for = exec_run._connection_for
    orig_ensure_keys = data.ensure_key_candidates
    data.clear_key_cache()
    data.clear_conn_names()
  end)

  after_each(function()
    exec_run._connection_for = orig_exec_run_connection_for
    data.ensure_key_candidates = orig_ensure_keys
    data.clear_key_cache()
  end)

  it("returns command items at the command position", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local items = nil
    completion._test.get_items(buf, "GETS", function(i) items = i end)
    assert.truthy(items)
    local labels = {}
    for _, i in ipairs(items) do labels[#labels + 1] = i.label end
    assert.same({ "GETSET" }, labels)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("command items insert a trailing space and a keyword kind", function()
    -- Redis syntax is `GET key` — accepting a command must yield `GET `
    -- (command + space), not `GET()` (Function-kind autoparens).
    local buf = vim.api.nvim_create_buf(false, true)
    local items = nil
    completion._test.get_items(buf, "GE", function(i) items = i end)
    assert.truthy(items)
    assert.is_true(#items > 0)
    for _, i in ipairs(items) do
      assert.equals(14, i.kind, "command item kind must be Keyword, not Function")
      assert.equals(i.label .. " ", i.insertText, "command insertText must carry a trailing space")
    end
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("returns no items at a comment", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local items = nil
    completion._test.get_items(buf, "# note", function(i) items = i end)
    assert.same({}, items)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("returns key items for an argument position when a connection exists", function()
    exec_run._connection_for = function(_buf) return "redis://h:6379/0", "srv" end
    data.ensure_key_candidates = function(_url, prefix, _db, cb)
      cb({ "user:1", "user:2", "other:9" })
    end
    local buf = vim.api.nvim_create_buf(false, true)
    local items = nil
    completion._test.get_items(buf, "GET user:", function(i) items = i end)
    local labels = {}
    for _, i in ipairs(items or {}) do labels[#labels + 1] = i.label end
    assert.same({ "user:1", "user:2" }, labels)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("returns no key items without a connection", function()
    exec_run._connection_for = function(_buf) return nil end
    local buf = vim.api.nvim_create_buf(false, true)
    local items = nil
    completion._test.get_items(buf, "GET user:", function(i) items = i end)
    assert.same({}, items)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)


describe("poste-redis key completion (task 0903 #10)", function()

  after_each(function()
    session_conn.execute = nil
    data.clear_key_cache()
  end)

  it("completes `GET ses` from SCAN MATCH ses* over the persistent session", function()
    local scanned
    local orig_conn_for = exec_run._connection_for
    exec_run._connection_for = function() return "redis://x", "stub" end
    session_conn.execute = function(url, cmd, cbs)
      scanned = table.concat(cmd, " ")
      cbs.on_response({ value = { value = { "session:abc", "session:xyz", "other" }, cursor = "0" } })
      return "dispatched"
    end
    local items
    completion.get_items(0, "GET ses", function(list) items = list end)
    assert.match("SCAN 0 MATCH ses", scanned)
    exec_run._connection_for = orig_conn_for
    local labels = {}
    for _, i in ipairs(items) do labels[#labels + 1] = i.label end
    assert.is_true(vim.tbl_contains(labels, "session:abc"))
    assert.is_false(vim.tbl_contains(labels, "other"))  -- prefix filter
  end)

  it("caps the candidate menu at completion_max_keys", function()
    require("poste-redis.config").config.completion_max_keys = 2
    session_conn.execute = function(url, cmd, cbs)
      cbs.on_response({ value = { value = { "ses:a", "ses:b", "ses:c" }, cursor = "0" } })
      return "dispatched"
    end
    local items
    data.ensure_key_candidates("redis://x", "ses", 0, function(list) items = list end)
    assert.equals(2, #items)
    require("poste-redis.config").config.completion_max_keys = 50
  end)

  it("skips the fetch entirely on an empty prefix (no full-db scan)", function()
    local called = false
    session_conn.execute = function() called = true; return "dispatched" end
    local items
    data.ensure_key_candidates("redis://x", "", 0, function(list) items = list end)
    assert.equals(0, #items)
    assert.is_false(called)
  end)
end)
