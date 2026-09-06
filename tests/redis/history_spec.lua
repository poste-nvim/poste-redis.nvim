--- history spec — in-memory execution history + float list.
local history = require("poste-redis.history")

describe("poste-redis history", function()
  local function entry(over)
    return vim.tbl_extend("force", {
      command = "GET k",
      connection = "my-redis",
      status = "\"v\"",
      latency_ms = 1,
      lines = { '"v"' },
    }, over or {})
  end

  after_each(function()
    history.close()
    history.clear()
  end)

  it("starts empty", function()
    assert.equals(0, history.count())
  end)

  it("push adds entries newest-first in list()", function()
    history.push(entry({ command = "GET a" }))
    history.push(entry({ command = "GET b" }))
    local items = history.list()
    assert.equals(2, #items)
    assert.equals("GET b", items[1].command)
    assert.equals("GET a", items[2].command)
  end)

  it("push captures status and latency", function()
    history.push(entry({ status = "PONG", latency_ms = 3 }))
    local items = history.list()
    assert.equals("PONG", items[1].status)
    assert.equals(3, items[1].latency_ms)
  end)

  it("respects the max cap", function()
    history.set_max_history(3)
    for i = 1, 5 do history.push(entry({ command = "GET " .. i })) end
    assert.equals(3, history.count())
    -- newest survive
    local items = history.list()
    assert.equals("GET 5", items[1].command)
    history.set_max_history(200)
  end)

  it("toggle opens a float window; an open toggle re-focuses and close tears it down", function()
    history.push(entry())
    assert.is_false(history.is_open())
    history.toggle()
    assert.is_true(history.is_open())
    -- already open: toggle focuses instead of closing, so the browse flow
    -- (sidebar ⇄ panel via <Tab>/<leader>rh) never loses the selection
    vim.api.nvim_set_current_win(0)
    history.toggle()
    assert.is_true(history.is_open())
    assert.equals(history.win(), vim.api.nvim_get_current_win())
    history.close()
    assert.is_false(history.is_open())
  end)

  it("<Tab> in the sidebar jumps focus to the result panel and keeps the sidebar open", function()
    history.push(entry())
    local buffer = require("poste-redis.buffer")
    history.toggle()
    assert.is_true(history.is_open())
    history.focus_panel()
    assert.equals(buffer.win(), vim.api.nvim_get_current_win())
    assert.is_true(history.is_open(), "sidebar stays open while the panel is focused")
    -- and <leader>rh (toggle) comes back to the sidebar
    history.toggle()
    assert.equals(history.win(), vim.api.nvim_get_current_win())
  end)

  it("activate rebuilds a real grid tab from the stored raw value", function()
    history.push(entry({
      command = "LRANGE k 0 -1",
      value = { type = "list", value = { "a", "b" }, len = 2 },
    }))
    local buffer = require("poste-redis.buffer")
    history.activate(1)
    assert.is_true(buffer.is_open())
    local tab = buffer.active_tab()
    -- a real grid: floating header, columns, key-stamped meta — not a text
    -- snapshot (which cannot show the grid header at all)
    assert.equals("table", tab.kind)
    assert.equals("value", tab.grid.columns[2])
    assert.equals("k", tab.meta.key)
    assert.equals("my-redis", tab.meta.connection)
    buffer.close()
  end)

  it("push stores the raw value and activate rides it into the snapshot meta", function()
    history.push(entry({ value = { type = "string", value = "v" } }))
    local buffer = require("poste-redis.buffer")
    history.activate(1)
    assert.is_true(buffer.is_open())
    local tab = buffer.active_tab()
    assert.same({ type = "string", value = "v" }, tab.meta.value)
    buffer.close()
  end)

  it("build renders the command left and the exec time right-aligned", function()
    history.push(entry({
      command = "HGETALL user:42",
      ts = os.time({ year = 2026, month = 9, day = 5, hour = 14, min = 3, sec = 7 }),
    }))
    local lines, spans = history._test.build(60)
    assert.truthy(lines[1]:find("HGETALL user:42", 1, true))
    -- the time sits pinned to the right edge, 8 chars wide
    assert.equals("14:03:07", lines[1]:sub(#lines[1] - 7))
    -- the command span is byte-accurate (the ✓ mark is multibyte)
    assert.equals("HGETALL user:42", lines[1]:sub(spans[1].cmd[1] + 1, spans[1].cmd[2]))
    assert.equals("14:03:07", lines[1]:sub(spans[1].time[1] + 1))
  end)

  it("long commands truncate and keep the time column aligned", function()
    history.push(entry({
      command = "GET " .. string.rep("k", 120),
      ts = os.time({ year = 2026, month = 9, day = 5, hour = 23, min = 59, sec = 59 }),
    }))
    local lines = history._test.build(60)
    assert.equals(60, vim.fn.strdisplaywidth(lines[1]))
    assert.equals("23:59:59", lines[1]:sub(#lines[1] - 7))
  end)

  it("y copies the command (the executable yank form wins)", function()
    history.push(entry({ command = "GET k" }))
    history.yank(1)
    assert.equals("GET k", vim.fn.getreg('"'))

    history.push(entry({
      command = "DEL bench:*",
      yank = "redis-cli --scan --pattern 'bench:*' | xargs redis-cli del",
    }))
    history.yank(1)
    assert.equals("redis-cli --scan --pattern 'bench:*' | xargs redis-cli del",
      vim.fn.getreg('"'))
  end)

  it("activate on a write entry renders the no-snapshot hint into the panel", function()
    history.push(entry({ command = "DEL k", kind = "write", lines = {} }))
    local buffer = require("poste-redis.buffer")
    history.activate(1)
    assert.is_true(buffer.is_open())
    local lines = vim.api.nvim_buf_get_lines(buffer.buf(), 0, -1, false)
    local text = table.concat(lines, "\n")
    assert.truthy(text:find("No result snapshot", 1, true))
    assert.truthy(text:find("DEL k", 1, true))
    buffer.close()
  end)

  it("activate keeps focus with enter = false (live j/k preview)", function()
    history.push(entry({ command = "GET k", lines = { "hello snapshot" } }))
    local buffer = require("poste-redis.buffer")
    local watcher = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(watcher)
    history.activate(1, false)
    assert.is_true(buffer.is_open())
    assert.equals(watcher, vim.api.nvim_get_current_buf(), "preview must not steal focus")
    local lines = vim.api.nvim_buf_get_lines(buffer.buf(), 0, -1, false)
    assert.truthy(table.concat(lines, "\n"):find("hello snapshot"))
    buffer.close()
  end)

  it("toggle opens the sidebar anchored beside the result panel", function()
    history.push(entry())
    local buffer = require("poste-redis.buffer")
    history.toggle()
    assert.is_true(history.is_open())
    local panel_win = buffer.win()
    assert.is_not_nil(panel_win)
    local config = vim.api.nvim_win_get_config(history.win())
    assert.equals("win", config.relative, "sidebar anchors to the result panel window")
    assert.equals(panel_win, config.win)
    -- nvim returns the col as a number or a { [anchor] = col } table
    local col = type(config.col) == "table" and config.col[false] or config.col
    assert.equals(vim.api.nvim_win_get_width(panel_win), col,
      "pinned just past the panel's (narrowed) right edge")
    -- the panel is a full-width split: it narrows while the sidebar is open
    -- so the float lands in freed columns instead of covering data
    assert.is_true(vim.api.nvim_win_get_width(panel_win) < vim.o.columns,
      "panel narrowed to make room for the sidebar")
    -- never reaches the panel's bottom edge, so the statusline stays visible
    local panel_h = vim.api.nvim_win_get_height(panel_win)
    assert.is_true(vim.api.nvim_win_get_height(history.win()) < panel_h)
    -- floats inherit the anchor's window options at open time: without the
    -- reset the sidebar picked up the panel's gray meta winhl
    assert.equals("Normal:Normal",
      vim.api.nvim_get_option_value("winhl", { win = history.win() }))
    history.close()
    assert.is_false(history.is_open())
    assert.equals(vim.o.columns, vim.api.nvim_win_get_width(panel_win),
      "panel gets its full width back when the sidebar closes")
  end)

  it("j/k in the sidebar previews the entry under the cursor in the panel", function()
    history.push(entry({ command = "GET a", lines = { '"a"' } }))
    history.push(entry({ command = "GET b", lines = { '"b"' } }))
    local buffer = require("poste-redis.buffer")
    history.toggle()
    local sidebar = history.win()
    local feed = vim.api.nvim_replace_termcodes("j", true, false, true)
    vim.api.nvim_feedkeys(feed, "mtx", false)
    vim.wait(50)
    -- cursor moved to line 2 = OLDER entry (GET a, newest-first list)
    assert.equals(2, vim.api.nvim_win_get_cursor(sidebar)[1])
    local lines = vim.api.nvim_buf_get_lines(buffer.buf(), 0, -1, false)
    assert.truthy(table.concat(lines, "\n"):find('"a"', 1, true),
      "the panel renders the entry under the cursor")
    history.close()
    buffer.close()
  end)

  it("activate re-renders the stored snapshot into the panel", function()
    history.push(entry({ command = "GET k", lines = { "hello snapshot" } }))
    history.activate(1)
    local buffer = require("poste-redis.buffer")
    assert.is_true(buffer.is_open())
    local lines = vim.api.nvim_buf_get_lines(buffer.buf(), 0, -1, false)
    assert.truthy(table.concat(lines, "\n"):find("hello snapshot"))
    buffer.close()
  end)

  it("build shows an empty placeholder with no history", function()
    local lines = history._test.build()
    assert.truthy(lines[1]:find("no history"))
  end)
end)
