--- format spec — value rendering for the five+ reply shapes.
--- Covers the acceptance matrix in EXECUTION-PLAN §8: (nil) / integer /
--- status string / array table / map table, plus binary hex digest.
local format = require("poste-redis.format")

describe("poste-redis format", function()
  local function lines_for(value)
    return format.format_result({
      seq = 1,
      command = "GET k",
      status = "",
      latency_ms = 1,
      value = value,
    })
  end

  it("renders nil as (nil)", function()
    local out = lines_for({ type = "nil", value = nil })
    assert.equals(1, #out.lines)
    assert.equals("(nil)", out.lines[1])
  end)

  it("renders an integer reply", function()
    local out = lines_for({ type = "integer", value = 42 })
    assert.equals("42", out.lines[1])
  end)

  it("renders a status string with a byte note", function()
    local out = lines_for({ type = "string", value = "PONG" })
    assert.equals('"PONG"', out.lines[1])
  end)

  it("renders a truncated string with a byte note", function()
    local out = lines_for({
      type = "string",
      value = "x",
      len = 2048,
      truncated = true,
    })
    assert.equals('"x"', out.lines[1])
    assert.truthy(out.lines[2]:find("2048"))
  end)

  it("renders a string that is also JSON (parsed stays raw on screen)", function()
    local out = lines_for({
      type = "string",
      value = '{"a": 1}',
      len = 8,
      parsed = { a = 1 },
    })
    assert.equals('"{"a": 1}"', out.lines[1])
  end)

  it("renders a list as a numbered table", function()
    local out = lines_for({ type = "list", value = { "a", "b", "c" }, len = 3 })
    assert.equals('1) a', out.lines[1])
    assert.equals('2) b', out.lines[2])
    assert.equals('3) c', out.lines[3])
  end)

  it("renders an empty list", function()
    local out = lines_for({ type = "list", value = {}, len = 0 })
    assert.equals("(empty list)", out.lines[1])
  end)

  it("renders a list capped by the binary with a truncation note", function()
    local out = lines_for({ type = "list", value = { "a" }, len = 1000, truncated = true })
    assert.truthy(out.lines[#out.lines]:find("capped") or out.lines[#out.lines]:find("truncated"))
  end)

  it("renders a hash (HGETALL) as a field/value table", function()
    local out = lines_for({
      type = "hash",
      entries = { { "name", "Alice" }, { "age", "30" } },
      len = 2,
    })
    local joined = table.concat(out.lines, "\n")
    assert.truthy(joined:find("Alice"))
    assert.truthy(joined:find("30"))
    assert.truthy(joined:find("field"))
    assert.truthy(joined:find("value"))
    -- boxed table
    assert.truthy(joined:find("┌"))
    assert.truthy(joined:find("┘"))
  end)

  it("renders a native Redis 7 map like a hash", function()
    local out = lines_for({ type = "hash", entries = { { "k", "v" } }, len = 1 })
    local joined = table.concat(out.lines, "\n")
    assert.truthy(joined:find("k"))
    assert.truthy(joined:find("v"))
  end)

  it("renders a zset with a score column", function()
    local out = lines_for({
      type = "zset",
      value = { { member = "alice", score = 99 }, { member = "bob", score = 87 } },
      len = 2,
    })
    local joined = table.concat(out.lines, "\n")
    assert.truthy(joined:find("alice"))
    assert.truthy(joined:find("99"))
    assert.truthy(joined:find("score"))
  end)

  it("renders a stream with id + fields", function()
    local out = lines_for({
      type = "stream",
      value = { { id = "1690000000000-0", fields = { { "to", "a@b.c" } } } },
      len = 1,
    })
    local joined = table.concat(out.lines, "\n")
    assert.truthy(joined:find("1690000000000-0"))
    assert.truthy(joined:find("to = a@b.c"))
  end)

  it("renders a binary reply as a hex digest + byte count", function()
    local out = lines_for({
      type = "binary",
      encoding = "hex",
      bytes = 4,
      preview = "48 65 ff 00",
    })
    assert.equals("(binary) 4 bytes", out.lines[1])
    assert.equals("hex: 48 65 ff 00", out.lines[2])
  end)

  it("renders an unknown type as its raw text", function()
    local out = lines_for({ type = "unknown", value = "Something" })
    assert.equals("Something", out.lines[1])
  end)

  it("renders a command error as an ERROR block", function()
    local out = format.format_result({
      seq = 2,
      command = "HSET bad key",
      status = "error",
      latency_ms = 1,
      error = "WRONGTYPE Operation against a key",
      value = { type = "nil", value = nil },
    })
    local joined = table.concat(out.lines, "\n")
    assert.equals("ERROR", out.lines[1])
    assert.truthy(joined:find("HSET bad key"))
    assert.truthy(joined:find("WRONGTYPE"))
    assert.equals("error", out.meta.status)
    assert.truthy(out.meta.error)
  end)

  it("does not mistake a status-less error for a value", function()
    local out = format.format_result({
      command = "FLUSHALL",
      status = "error",
      error = "NOPERM",
    })
    assert.equals("ERROR", out.lines[1])
  end)

  it("caps rendered rows for very large collections", function()
    local big = {}
    for i = 1, 500 do big[#big + 1] = tostring(i) end
    local out = lines_for({ type = "list", value = big, len = 500 })
    assert.truthy(#out.lines < 500)
    assert.truthy(out.lines[#out.lines]:find("more") or out.lines[#out.lines]:find("total"))
  end)

  it("format_error produces a readable block", function()
    local lines = format.format_error("boom: bad thing", "SET k v")
    assert.equals("ERROR", lines[1])
    assert.truthy(lines[2]:find("SET k v"))
    assert.truthy(lines[3]:find("boom"))
  end)

  it("preview_json pretty-encodes the raw value", function()
    local s = format.preview_json({ type = "string", value = "hi", len = 2 })
    assert.match('"type"', s)
    assert.match('"hi"', s)
    assert.match('\n', s)
  end)

  it("preview_json falls back to a string for non-encodable values", function()
    local s = format.preview_json("plain")
    assert.equals('"plain"', s)
  end)

  it("status_summary shows latency and status", function()
    assert.equals("2 ms · PONG", format.status_summary({ status = "PONG", latency_ms = 2 }))
    assert.match("✘", format.status_summary({ status = "error", latency_ms = 3 }))
    assert.equals("", format.status_summary({ status = "" }))
    assert.equals("1.50 s · OK", format.status_summary({ status = "OK", latency_ms = 1500 }))
  end)

  it("flags dangerous commands", function()
    assert.is_true(format.is_dangerous_command("FLUSHALL"))
    assert.is_true(format.is_dangerous_command("config set save ''"))
    assert.is_false(format.is_dangerous_command("GET k"))
  end)

  it("survives a malformed value table", function()
    local out = lines_for({ type = "weird" })
    assert.is_table(out.lines)
    assert.truthy(#out.lines > 0)
  end)

  it("handles CJK content without mangling display", function()
    local out = lines_for({ type = "string", value = "日本語" })
    assert.equals('"日本語"', out.lines[1])
  end)
end)
