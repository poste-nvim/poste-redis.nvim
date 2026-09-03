--- runner spec - request-line indicators must land on the source buffer's
--- sign column, never inside the result panel (regression: present() looked
--- up the current buffer after the panel took focus).
local runner = require("poste-redis.runner")
local exec_run = require("poste-redis.exec_run")
local state = require("poste.state")
local buffer = require("poste-redis.buffer")
local history = require("poste-redis.history")
local indicators = require("poste.indicators")

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
    pcall(vim.api.nvim_buf_delete, src, { force = true })
  end)

  it("spins on the source line while running", function()
    exec_run.run_selection_async = function(buf, mode, opts, callbacks)
      callbacks.on_start(1, 42)
    end
    runner.run_selection("cursor")
    assert.is_true(has_sign(src, 0, "PosteSpin1"))
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
end)
