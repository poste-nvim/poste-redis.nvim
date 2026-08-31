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

  it("build_lines renders command + latency", function()
    history.push(entry({ command = "HGETALL user:42", latency_ms = 1500 }))
    local lines = history._test.build_lines()
    assert.truthy(#lines >= 1)
    assert.truthy(lines[1]:find("HGETALL"))
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

  it("build_lines shows an empty placeholder with no history", function()
    local lines = history._test.build_lines()
    assert.truthy(lines[1]:find("no history"))
  end)
end)
