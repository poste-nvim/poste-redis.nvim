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

  it("toggle opens a float window and close tears it down", function()
    history.push(entry())
    assert.is_false(history.is_open())
    history.toggle()
    assert.is_true(history.is_open())
    history.toggle()
    assert.is_false(history.is_open())
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

  it("activate on a write entry (no snapshot) renders nothing", function()
    history.push(entry({ command = "DEL k", kind = "write", lines = {} }))
    local buffer = require("poste-redis.buffer")
    history.activate(1)
    assert.is_false(buffer.is_open())
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
