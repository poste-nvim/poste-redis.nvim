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
end)
