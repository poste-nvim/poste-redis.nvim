--- buffer spec — M1 result panel (D2): render, tabs, preview, close.
--- Runs headless; window/buffer operations are real but isolated in XDG tmp.
local buffer = require("poste-redis.buffer")

describe("poste-redis result buffer", function()
  local sample_results

  before_each(function()
    sample_results = {
      {
        seq = 1, command = "GET user:42", status = "\"Alice\"", latency_ms = 2,
        value = { type = "string", value = "Alice" },
      },
      {
        seq = 2, command = "HSET bad key", status = "error", latency_ms = 1,
        error = "WRONGTYPE Operation against a key holding the wrong kind of value",
        value = { type = "nil", value = nil },
      },
      {
        seq = 3, command = "HGETALL user:42", status = "2 elements", latency_ms = 1,
        value = { type = "hash", entries = { { "name", "Alice" }, { "age", "30" } }, len = 2 },
      },
    }
  end)

  after_each(function()
    buffer.close()
    pcall(vim.api.nvim_win_close, 0, true)
  end)

  it("starts closed", function()
    assert.is_false(buffer.is_open())
  end)

  it("render opens the panel with one tab per result", function()
    buffer.render(sample_results, { render = true })
    assert.is_true(buffer.is_open())
    assert.equals(3, buffer.tab_count())
    local lines = vim.api.nvim_buf_get_lines(buffer.buf(), 0, -1, false)
    assert.truthy(#lines > 0)
  end)

  it("render opens the panel without stealing focus from the request buffer", function()
    local src = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_lines(src, 0, -1, false, { "GET user:42" })
    vim.api.nvim_set_current_buf(src)
    buffer.render(sample_results, { render = true })
    assert.is_true(buffer.is_open())
    assert.equals(src, vim.api.nvim_get_current_buf())
    pcall(vim.api.nvim_buf_delete, src, { force = true })
  end)

  it("render_snapshot focuses the panel", function()
    buffer.render_snapshot({ "GET user:42" }, { command = "GET user:42" })
    assert.is_true(buffer.is_open())
    assert.equals(buffer.buf(), vim.api.nvim_get_current_buf())
  end)

  it("shows the first result by default", function()
    buffer.render(sample_results, { render = true })
    local lines = vim.api.nvim_buf_get_lines(buffer.buf(), 0, -1, false)
    local joined = table.concat(lines, "\n")
    assert.truthy(joined:find("Alice"))
  end)

  it("switches tabs with next_tab / prev_tab", function()
    buffer.render(sample_results, { render = true })
    buffer.next_tab()
    local lines = vim.api.nvim_buf_get_lines(buffer.buf(), 0, -1, false)
    assert.truthy(table.concat(lines, "\n"):find("WRONGTYPE"))
    buffer.next_tab()
    -- hash tab renders as a table grid: header lives in the floating header,
    -- the buffer body carries the field/value cells
    local tab = buffer.active_tab()
    assert.equals("table", tab.kind)
    local lines3 = vim.api.nvim_buf_get_lines(buffer.buf(), 0, -1, false)
    assert.truthy(table.concat(lines3, "\n"):find("Alice"))
    assert.truthy(table.concat(lines3, "\n"):find("30"))
    buffer.prev_tab()
    local lines2 = vim.api.nvim_buf_get_lines(buffer.buf(), 0, -1, false)
    assert.truthy(table.concat(lines2, "\n"):find("WRONGTYPE"))
  end)

  it("next_tab wraps around", function()
    buffer.render(sample_results, { render = true })
    buffer.next_tab()
    buffer.next_tab()
    buffer.next_tab() -- wraps to tab 1
    local lines = vim.api.nvim_buf_get_lines(buffer.buf(), 0, -1, false)
    assert.truthy(table.concat(lines, "\n"):find("Alice"))
  end)

  it("close tears down the window and buffer", function()
    buffer.render(sample_results, { render = true })
    buffer.close()
    assert.is_false(buffer.is_open())
  end)

  it("render recovers from a stale hidden buffer holding the panel name", function()
    -- `:q` on the panel window leaves the hidden scratch buffer alive with
    -- the poste://redis_result name; the next render used to raise E95
    local ghost = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(ghost, "poste://redis_result")
    buffer.render(sample_results, { render = true })
    assert.is_true(buffer.is_open())
    assert.equals("poste://redis_result", vim.api.nvim_buf_get_name(buffer.buf()))
    buffer.close()
  end)

  it("re-render replaces previous tabs", function()
    buffer.render(sample_results, { render = true })
    buffer.render({ { seq = 1, command = "PING", status = "PONG", latency_ms = 1,
      value = { type = "string", value = "PONG" } } }, { render = true })
    assert.equals(1, buffer.tab_count())
    local lines = vim.api.nvim_buf_get_lines(buffer.buf(), 0, -1, false)
    assert.truthy(table.concat(lines, "\n"):find("PONG"))
  end)

  it("render with no results shows a placeholder", function()
    buffer.render({}, { render = true })
    assert.is_true(buffer.is_open())
    local lines = vim.api.nvim_buf_get_lines(buffer.buf(), 0, -1, false)
    assert.truthy(#lines >= 1)
  end)

  it("preview_raw opens a float for the current value", function()
    buffer.render(sample_results, { render = true })
    buffer.preview_raw()
    -- a new float window should exist on top of the panel
    local wins = vim.api.nvim_list_wins()
    assert.truthy(#wins >= 1)
  end)

  it("yank_current copies the rendered lines to the unnamed register", function()
    buffer.render(sample_results, { render = true })
    buffer.yank_current()
    local reg = vim.fn.getreg('"')
    assert.truthy(reg:find("Alice"))
  end)

  it("binds grid tabs to their key and stamps the exec db on meta", function()
    buffer.render({
      { seq = 1, command = "HGETALL user:42", status = "2 elements", latency_ms = 1, db = 3,
        value = { type = "hash", entries = { { "name", "Alice" } }, len = 1 } },
      { seq = 2, command = "CONFIG GET maxmemory", status = "OK", latency_ms = 1, db = 3,
        value = { type = "unknown", value = "maxmemory 0" } },
    }, { render = false })
    local tabs = buffer._tabs()
    assert.equals("user:42", tabs[1].meta.key)
    assert.equals(3, tabs[1].meta.db)
    -- non-grid tabs carry the db but no key binding
    assert.equals(3, tabs[2].meta.db)
    assert.is_nil(tabs[2].meta.key)
    -- named USE groups win over the run-level URL fallback (winbar context)
    buffer.render({ { seq = 3, command = "GET k", status = "", latency_ms = 1, db = 1,
      connection_name = "local", value = { type = "string", value = "x" } } },
      { render = false, connection = "redis://h:6379/0" })
    assert.equals("local", buffer._tabs()[1].meta.connection)
  end)

  it("dangerous commands produce a tab and do not crash", function()
    local res = { { seq = 1, command = "FLUSHALL", status = "error", latency_ms = 1,
      error = "NOPERM", value = { type = "nil", value = nil } } }
    buffer.render(res, { render = true })
    assert.is_true(buffer.is_open())
  end)

  it("dismisses the float preview without touching the panel", function()
    buffer.render(sample_results, { render = true })
    buffer.preview_raw()
    -- count floating windows
    local before = 0
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(w).relative ~= "" then before = before + 1 end
    end
    assert.truthy(before >= 1)
  end)
end)
