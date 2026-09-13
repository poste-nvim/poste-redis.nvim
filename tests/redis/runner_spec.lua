--- runner spec - request-line indicators must land on the source buffer's
--- sign column, never inside the result panel (regression: present() looked
--- up the current buffer after the panel took focus).
local runner = require("poste-redis.runner")
local exec_run = require("poste-redis.exec_run")
local state = require("poste-redis.state")
local buffer = require("poste-redis.buffer")
local history = require("poste-redis.history")
local indicators = require("poste-redis.indicators")
local connections = require("poste-redis.connections")
local redis_state = require("poste-redis.state")
local orig_resolve = connections.resolve_redis_url

local SIGN_GROUP = "poste_sg_4a7f_indicator"

local function sign_names(buf, line_0)
  local names = {}
  local placed = vim.fn.sign_getplaced(buf, { group = SIGN_GROUP })
  for _, entry in ipairs(placed or {}) do
    for _, s in ipairs(entry.signs or {}) do
      if line_0 == nil or s.lnum == line_0 + 1 then
        names[#names + 1] = s.name
      end
    end
  end
  return names
end

local function has_sign(buf, line_0, name)
  return vim.tbl_contains(sign_names(buf, line_0), name)
end

describe("poste-redis runner indicators", function()
  local src
  local orig_run_selection = exec_run.run_selection_async
  local orig_run_file = exec_run.run_file_async
  local orig_find_binary = state.find_poste_binary

  before_each(function()
    src = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_lines(src, 0, -1, false, { "GET e2e:key" })
    vim.api.nvim_set_current_buf(src)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    state.find_poste_binary = function() return "/tmp/poste-redis-fake-binary" end
    buffer.close()
    history.clear()
  end)

  after_each(function()
    indicators.clear_all(src)
    buffer.close()
    exec_run.cancel()
    exec_run.run_selection_async = orig_run_selection
    exec_run.run_file_async = orig_run_file
    state.find_poste_binary = orig_find_binary
    -- context leaks: a stubbed resolve or a stale current_url would make a
    -- later render fire the winbar TTL probe through the fake binary
    connections.resolve_redis_url = orig_resolve
    redis_state.current_url = nil
    redis_state.context.connection = nil
    redis_state.context.db = nil
    pcall(vim.api.nvim_buf_delete, src, { force = true })
  end)

  it("spins on the source line while running", function()
    exec_run.run_selection_async = function(buf, mode, opts, callbacks)
      callbacks.on_start(1, 42)
    end
    runner.run_selection("cursor")
    assert.is_true(has_sign(src, 0, "PosteSpin1"))
  end)

  it("<CR> on a USE line applies that connection instead of erroring", function()
    vim.api.nvim_buf_set_lines(src, 0, -1, false, { "USE srv", "GET k" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    connections.resolve_redis_url = function(name)
      return "redis://" .. name .. ":6379/0", nil
    end
    runner.run_selection("cursor")
    assert.equals("redis://srv:6379/0", redis_state.current_url)
    assert.equals("srv", redis_state.context.connection)
    -- no execution was started and no "Nothing to execute" noise appeared
    assert.is_false(exec_run.is_busy())
  end)

  it("<CR> on a bare USE opens the connection picker", function()
    vim.api.nvim_buf_set_lines(src, 0, -1, false, { "USE" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local picked = false
    connections.select_connection = function() picked = true end
    runner.run_selection("cursor")
    assert.is_true(picked)
    assert.is_nil(redis_state.current_url)
  end)

  it("places success on the source buffer, not the result panel", function()
    exec_run.run_selection_async = function(buf, mode, opts, callbacks)
      callbacks.on_start(1, 42)
      callbacks.on_done({
        {
          seq = 1, command = "GET e2e:key", status = "PONG", latency_ms = 1,
          value = { type = "string", value = "PONG" },
        },
      }, {})
    end
    runner.run_selection("cursor")
    assert.is_true(has_sign(src, 0, "PosteIndicatorSuccess"))
    assert.is_false(vim.tbl_contains(sign_names(src, 0), "PosteSpin1"))
    local panel = buffer.buf()
    assert.is_truthy(panel)
    assert.is_false(has_sign(panel, 0, "PosteIndicatorSuccess"))
    assert.equals(src, vim.api.nvim_get_current_buf())
  end)

  it("line runs show no indicator on the inherited SELECT line", function()
    vim.api.nvim_buf_set_lines(src, 0, -1, false, { "USE local", "SELECT 3", "GET session:abc" })
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    exec_run.run_selection_async = function(_buf, _mode, _opts, callbacks)
      callbacks.on_start(1, 42)
      callbacks.on_done({
        { seq = 1, command = "GET session:abc", status = "\"v\"", latency_ms = 1, value = { type = "string", value = "v" } },
      }, {})
    end
    runner.run_selection("cursor")
    -- the inherited SELECT runs invisibly: the GET succeeds on its line,
    -- the SELECT line keeps no sign at all
    assert.is_true(has_sign(src, 2, "PosteIndicatorSuccess"))
    assert.is_false(has_sign(src, 1, "PosteIndicatorSuccess"))
    assert.is_false(has_sign(src, 1, "PosteSpin1"))
  end)

  it("the inherited SELECT runs invisibly: no phantom tab, result, or indicator", function()
    -- regression: the runner once injected into ITS entry list while
    -- exec_run re-derived entries from the buffer — the SELECT never ran
    -- (db stayed 0) and its phantom result/indicator cluttered the run
    local cli = require("poste-redis.cli")
    local session_conn = require("poste-redis.session_conn")
    local orig_run_async = cli.run_async
    local orig_execute = session_conn.execute
    cli.run_async = function(_cmd, opts)
      local payload = vim.json.decode(opts.stdin)
      assert.same({ "SELECT", "3" }, payload.commands[1])
      assert.same({ "GET", "session:abc" }, payload.commands[2])
      -- async emission (matches the real jobstart ordering: on_start fires
      -- before any result lands, so success replaces the spinners)
      vim.schedule(function()
        opts.on_stdout({
          vim.json.encode({ type = "result", seq = 1, command = "SELECT 3", status = "OK", latency_ms = 1, value = { type = "string", value = "OK" } }),
          vim.json.encode({ type = "result", seq = 2, command = "GET session:abc", status = "\"v\"", latency_ms = 1, value = { type = "string", value = "v" } }),
          vim.json.encode({ type = "summary", total = 2, failed = 0, elapsed_ms = 1 }),
        })
        opts.on_stderr({})
        opts.on_exit(0)
      end)
      return 99
    end
    -- the sandbox has no connections.toml, and the winbar TTL probe would
    -- hit the fake binary via the session
    connections.resolve_redis_url = function(_name) return "redis://stub:6379/0", nil end
    session_conn.execute = function() return "skipped" end
    vim.api.nvim_buf_set_lines(src, 0, -1, false, { "USE local", "SELECT 3", "GET session:abc" })
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    runner.run_selection("cursor")
    assert.is_true(vim.wait(2000, function()
      return has_sign(src, 2, "PosteIndicatorSuccess")
    end, 10), "GET indicator never landed")
    -- no indicator on the SELECT line, and the panel shows exactly one tab
    -- (the GET) — the SELECT's OK result is swallowed
    assert.is_false(has_sign(src, 1, "PosteIndicatorSuccess"))
    assert.is_false(has_sign(src, 1, "PosteSpin1"))
    assert.equals(1, buffer.tab_count())
    assert.equals("GET session:abc", buffer.active_tab().meta.command)
    assert.equals(3, buffer.active_tab().meta.db)
    local wb = vim.api.nvim_get_option_value("winbar", { win = buffer.win() })
    assert.match("db3", wb)
    cli.run_async = orig_run_async
    session_conn.execute = orig_execute
    connections.resolve_redis_url = orig_resolve
  end)

  it("places success on the source buffer when running the file", function()
    exec_run.run_file_async = function(buf, opts, callbacks)
      callbacks.on_done({
        {
          seq = 1, command = "GET e2e:key", status = "PONG", latency_ms = 1,
          value = { type = "string", value = "PONG" },
        },
      }, {})
    end
    runner.run_file()
    assert.is_true(has_sign(src, 0, "PosteIndicatorSuccess"))
    local panel = buffer.buf()
    assert.is_false(has_sign(panel, 0, "PosteIndicatorSuccess"))
    assert.equals(src, vim.api.nvim_get_current_buf())
  end)

  it("passes the selected context to run_file so pre-USE commands run", function()
    -- regression: :PosteRedisConnection then re-running a USE-less file still
    -- errored with "No connection for line 1" — the selection never reached
    -- group_by_connection as the default URL.
    redis_state.current_url = "redis://selected:6379/0"
    redis_state.context.connection = "selected"
    local captured
    exec_run.run_file_async = function(buf, opts, callbacks)
      captured = opts
      callbacks.on_done({}, {})
    end
    runner.run_file()
    assert.equals("redis://selected:6379/0", captured.connection)
  end)

  it("runs every statement in a visual range, not just the cursor line", function()
    vim.api.nvim_buf_set_lines(src, 0, -1, false, { "GET a", "GET b", "GET c" })
    local captured
    exec_run.run_selection_async = function(buf, mode, opts, callbacks)
      captured = { mode = mode, range = opts.range }
      callbacks.on_start(1, 42)
      callbacks.on_done({
        { seq = 1, command = "GET a", status = "OK", latency_ms = 1 },
        { seq = 2, command = "GET b", status = "OK", latency_ms = 1 },
      }, {})
    end
    -- cursor sits on line 3 (the LAST line of the selection); the visual
    -- range captured by the keymap covers lines 1-2
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    runner.run_selection("visual", { start_line = 1, end_line = 2 })
    assert.equals("visual", captured.mode)
    assert.same({ start_line = 1, end_line = 2 }, captured.range)
    -- spinners ran on both statement lines, and both got a success indicator
    assert.is_true(has_sign(src, 0, "PosteIndicatorSuccess"))
    assert.is_true(has_sign(src, 1, "PosteIndicatorSuccess"))
    assert.is_false(has_sign(src, 2, "PosteIndicatorSuccess"))
    assert.is_false(vim.tbl_contains(sign_names(src, 0), "PosteSpin1"))
    assert.is_false(vim.tbl_contains(sign_names(src, 1), "PosteSpin1"))
  end)

  it("marks each executed statement with its own per-line result", function()
    vim.api.nvim_buf_set_lines(src, 0, -1, false, { "GET ok", "GET bad", "GET ok2" })
    exec_run.run_selection_async = function(buf, mode, opts, callbacks)
      callbacks.on_done({
        { seq = 1, command = "GET ok", status = "OK", latency_ms = 1 },
        { seq = 2, command = "GET bad", status = "error", error = "boom", latency_ms = 1 },
        { seq = 3, command = "GET ok2", status = "OK", latency_ms = 1 },
      }, {})
    end
    runner.run_selection("visual", { start_line = 1, end_line = 3 })
    assert.is_true(has_sign(src, 0, "PosteIndicatorSuccess"))
    assert.is_true(has_sign(src, 1, "PosteIndicatorError"))
    assert.is_true(has_sign(src, 2, "PosteIndicatorSuccess"))
  end)

  it("clears the previous run's indicator before a new run", function()
    vim.api.nvim_buf_set_lines(src, 0, -1, false, { "GET one", "GET two" })
    exec_run.run_selection_async = function(buf, mode, opts, callbacks)
      callbacks.on_done({
        { seq = 1, command = "GET one", status = "OK", latency_ms = 1 },
      }, {})
    end
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    runner.run_selection("cursor")
    assert.is_true(has_sign(src, 0, "PosteIndicatorSuccess"))

    -- second run on line 2 must not leave line 1's stale sign behind
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    runner.run_selection("cursor")
    assert.is_true(has_sign(src, 1, "PosteIndicatorSuccess"))
    assert.is_false(has_sign(src, 0, "PosteIndicatorSuccess"))
  end)

  it("cancel_current stops a running run and clears its spinners", function()
    -- <Esc> used to have no binding at all while the busy notification told
    -- the user to "press <Esc> to cancel first" — exec_run.cancel existed
    -- (tested) but nothing user-reachable ever called it.
    local cli = require("poste-redis.cli")
    local orig_run_async = cli.run_async
    cli.run_async = function(_cmd, _opts) return 4242 end  -- job "in flight"
    redis_state.current_url = "redis://stub:6379/0"  -- _connection_for path
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    runner.run_selection("cursor")
    assert.is_true(exec_run.is_busy(), "run never became busy")
    assert.is_true(has_sign(src, 0, "PosteSpin1"))
    cli.run_async = orig_run_async

    assert.is_true(runner.cancel_current(src))
    assert.is_false(exec_run.is_busy())
    assert.is_false(has_sign(src, 0, "PosteSpin1"), "spinner survived the cancel")

    -- idle cancel: a no-op, not an error
    assert.is_false(runner.cancel_current(src))
  end)
end)

--- Regression: the visual <CR> keymap used to read the '< '> marks, which
--- are only written AFTER visual mode ends — a fresh buffer's first selection
--- read 0/0 ("No command at cursor") and any later run executed the PREVIOUS
--- selection's lines (stale indicators). The keymap now captures the live `v`
--- mark + cursor, so feedkeys drives the real capture path here.
describe("poste-redis visual keymap capture", function()
  local buffer_setup = require("poste-redis.buffer_setup")
  local orig_find_binary = state.find_poste_binary
  local orig_run_selection = exec_run.run_selection_async
  local src

  before_each(function()
    src = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_lines(src, 0, -1, false, {
      "ZADD leaderboard:test:demo 920 \"player_a\"",
      "ZADD leaderboard:test:demo 850 \"player_b\"",
      "ZADD leaderboard:test:demo 780 \"player_c\"",
    })
    vim.api.nvim_set_current_buf(src)
    buffer_setup.setup_buffer_keymaps(src)
    state.find_poste_binary = function() return "poste" end
  end)

  after_each(function()
    state.find_poste_binary = orig_find_binary
    exec_run.run_selection_async = orig_run_selection
  end)

  local function run_keys(keys)
    local captured
    exec_run.run_selection_async = function(_buf, mode, opts, _cbs)
      captured = { mode = mode, entries = opts.entries }
      return nil
    end
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "mtx", false)
    return captured
  end

  it("first-ever selection on a fresh buffer runs the selected lines", function()
    local captured = run_keys("ggVjj<CR>")
    assert.is_not_nil(captured, "visual keymap did not fire")
    assert.equals("visual", captured.mode)
    assert.equals(3, #captured.entries, "all three selected statements ran")
    assert.equals("ZADD", captured.entries[1].command)
  end)

  it("bottom-up selection runs the same lines, in file order", function()
    local captured = run_keys("GVkk<CR>")
    assert.is_not_nil(captured, "visual keymap did not fire")
    assert.equals(3, #captured.entries)
    assert.equals('"player_a"', captured.entries[1].tokens[4])
    assert.equals('"player_c"', captured.entries[3].tokens[4])
  end)
end)
