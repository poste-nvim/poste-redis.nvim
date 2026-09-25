--- format spec — value rendering for the five+ reply shapes.
--- Covers the acceptance matrix in EXECUTION-PLAN §8: (nil) / integer /
--- status string / array table / map table, plus binary hex digest.
local format = require("poste-redis.format")
local icons = require("poste-redis.icons")

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

  it("renders a large integer reply with all its digits", function()
    -- tostring() (the old path) uses %.14g: an INCR'd microsecond counter
    -- showed as "1.75e+15" even though the double holds it exactly
    local out = lines_for({ type = "integer", value = 1750000000000000 })
    assert.equals("1750000000000000", out.lines[1])
  end)

  it("renders zset scores through the same number rule", function()
    local out = lines_for({
      type = "zset",
      len = 1,
      value = { { member = "m", score = 1750000000000000 } },
    })
    assert.equals("table", out.kind)
    assert.same({ 1, "m", 1750000000000000 }, out.grid.rows[1])
    -- the raw cell is kept; only the display transform widens it to digits
    assert.equals("1750000000000000", out.grid.to_display(out.grid.rows[1][3]))
  end)

  it("renders a non-finite score the binary sends as text", function()
    -- serde_json has no spelling for infinity, so poste.nvim sends the reading
    -- Redis itself uses for such a score: `inf`. It has to reach the score
    -- column as that text — before, an infinite score arrived as JSON null
    -- and the panel said "(nil)" — stay right-aligned, and yank verbatim.
    local out = lines_for({
      type = "zset",
      len = 1,
      value = { { member = "m", score = "inf" } },
    })
    assert.same({ 1, "m", "inf" }, out.grid.rows[1])
    assert.equals("inf", out.grid.to_display(out.grid.rows[1][3]))
    assert.equals("inf", out.grid.to_copy(out.grid.rows[1][3]))
    assert.same({ 3 }, out.grid.right_align)
  end)

  it("renders a string reply through the type-labeled grid", function()
    local out = lines_for({ type = "string", value = "hello world" })
    assert.equals("table", out.kind)
    assert.same({ icons.type_label("string"), "value" }, out.grid.columns)
    assert.same({ 1, "hello world" }, out.grid.rows[1])
    assert.equals("PosteRedisBrowserString", out.grid.type_hl)
  end)

  it("renders a truncated string as a grid with the truncation flag", function()
    local out = lines_for({
      type = "string",
      value = "x",
      len = 2048,
      truncated = true,
    })
    assert.equals("table", out.kind)
    assert.same({ 1, "x" }, out.grid.rows[1])
    assert.is_true(out.grid.truncated)
  end)

  it("renders a JSON string raw in the grid cell (parsed stays out)", function()
    local out = lines_for({
      type = "string",
      value = '{"a": 1}',
      len = 8,
      parsed = { a = 1 },
    })
    assert.equals("table", out.kind)
    assert.same({ 1, '{"a": 1}' }, out.grid.rows[1])
  end)

  it("renders a list as a table grid with an index column", function()
    local out = lines_for({ type = "list", value = { "a", "b", "c" }, len = 3 })
    assert.equals("table", out.kind)
    assert.same({ icons.type_label("list"), "value" }, out.grid.columns)
    assert.same({ 1, "a" }, out.grid.rows[1])
    assert.same({ 3, "c" }, out.grid.rows[3])
    assert.equals(3, out.grid.total)
  end)

  it("renders an empty list as an empty grid", function()
    local out = lines_for({ type = "list", value = {}, len = 0 })
    assert.equals("table", out.kind)
    assert.equals(0, #out.grid.rows)
  end)

  it("renders a list capped by the binary with a truncation note", function()
    local out = lines_for({ type = "list", value = { "a" }, len = 1000, truncated = true })
    assert.equals("table", out.kind)
    assert.is_true(out.grid.truncated)
    assert.equals(1000, out.grid.total)
    assert.equals(1, #out.grid.rows)
  end)

  it("renders a hash (HGETALL) as a field/value grid", function()
    local out = lines_for({
      type = "hash",
      entries = { { "name", "Alice" }, { "age", "30" } },
      len = 2,
    })
    assert.equals("table", out.kind)
    assert.same({ icons.type_label("hash"), "field", "value" }, out.grid.columns)
    assert.same({ 1, "name", "Alice" }, out.grid.rows[1])
    assert.same({ 2, "age", "30" }, out.grid.rows[2])
  end)

  it("renders a native Redis 7 map like a hash", function()
    local out = lines_for({ type = "hash", entries = { { "k", "v" } }, len = 1 })
    assert.equals("table", out.kind)
    assert.same({ 1, "k", "v" }, out.grid.rows[1])
  end)

  it("renders a zset with a score column", function()
    local out = lines_for({
      type = "zset",
      value = { { member = "alice", score = 99 }, { member = "bob", score = 87 } },
      len = 2,
    })
    assert.equals("table", out.kind)
    assert.same({ icons.type_label("zset"), "member", "score" }, out.grid.columns)
    assert.same({ 1, "alice", 99 }, out.grid.rows[1])
    assert.same({ 2, "bob", 87 }, out.grid.rows[2])
    -- score column is right-aligned
    assert.same({ 3 }, out.grid.right_align)
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

  it("shows the binary marker in a hash row, not (nil)", function()
    -- The binary shape carries a one-line `value` for exactly this: a nested
    -- cell holds the child's scalar, and a msgpack/protobuf field with no
    -- scalar read as an empty row while the key holds bytes.
    local out = lines_for({
      type = "hash",
      entries = { { "blob", "(binary) 4 bytes hex: 48 65 ff 00" } },
      len = 1,
    })
    assert.equals("table", out.kind)
    assert.same({ 1, "blob", "(binary) 4 bytes hex: 48 65 ff 00" }, out.grid.rows[1])
    assert.equals("(binary) 4 bytes hex: 48 65 ff 00", out.grid.to_display(out.grid.rows[1][3]))
  end)

  it("renders RESP3 typed scalars as their value", function()
    -- `?protocol=resp3` in the connection URL types replies the RESP2 shapes
    -- never carry; an unlisted type name still has to print something useful
    local number = lines_for({ type = "number", value = 1.5 })
    assert.equals("1.5", table.concat(number.lines, ""))
    assert.equals("true", table.concat(lines_for({ type = "boolean", value = true }).lines, ""))
    -- a wide integer arrives as digits in a string so it does not round
    local big = lines_for({ type = "integer", value = "123456789012345678901234567890" })
    assert.equals("123456789012345678901234567890", table.concat(big.lines, ""))
    -- A string-valued text line must stay ONE line: `cell` returns gsub's
    -- substitution count as a second value, and `{ cell(v) }` splices it in as
    -- a phantom extra row the panel then writes into the buffer.
    for _, out in ipairs({ big, number, lines_for({ type = "unknown", value = "SomeReply" }) }) do
      assert.equals(1, #out.lines)
      assert.equals("string", type(out.lines[1]))
    end
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

  it("renders an error that carries no value as an ERROR block", function()
    local out = format.format_result({
      command = "FLUSHALL",
      status = "error",
      error = "NOPERM",
    })
    assert.equals("ERROR", out.lines[1])
  end)

  it("caps rendered rows for very large collections", function()
    local big = {}
    for i = 1, 1500 do big[#big + 1] = tostring(i) end
    local out = lines_for({ type = "list", value = big, len = 1500 })
    assert.equals("table", out.kind)
    assert.equals(format._test.GRID_MAX_ROWS, #out.grid.rows)
    assert.is_true(out.grid.truncated)
    assert.equals(1500, out.grid.total)
  end)

  it("format_error produces a readable block", function()
    local lines = format.format_error("boom: bad thing", "SET k v")
    assert.equals("ERROR", lines[1])
    assert.truthy(lines[2]:find("SET k v"))
    assert.truthy(lines[3]:find("boom"))
  end)

  it("format_error keeps the command on one buffer line", function()
    -- the decoded form of `GET "a\nb"` carries a real newline; the panel
    -- sets these lines with nvim_buf_set_lines, which rejects embedded
    -- newlines — the whole error block must survive as flat lines
    local lines = format.format_error("WRONGTYPE", 'GET "a\nb"')
    assert.equals(3, #lines)
    for _, l in ipairs(lines) do
      assert.falsy(l:find("\n"))
    end
    assert.truthy(lines[2]:find("a⏎b"))
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

  it("status_summary shows the length for string replies, not the value", function()
    local jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0"
    assert.equals("4 ms · len 40", format.status_summary({
      status = '"' .. jwt .. '"', latency_ms = 4,
      value = { type = "string", value = jwt },
    }))
    -- non-string values keep the exec status text; the error path wins over both
    assert.equals("2 ms · 2 elements", format.status_summary({
      status = "2 elements", latency_ms = 2,
      value = { type = "hash", entries = { { "a", "1" } }, len = 2 },
    }))
    assert.equals("✘ 1 ms", format.status_summary({
      status = "error", latency_ms = 1, error = "WRONGTYPE",
      value = { type = "string", value = "x" },
    }))
    -- a reply the binary cut (--max-bytes): `len` is the real size, so the
    -- winbar must not report the cap as the value's length
    assert.equals("9 ms · len 50000000, truncated", format.status_summary({
      status = ("x"):rep(64), latency_ms = 9,
      value = { type = "string", value = ("x"):rep(64), len = 50000000, truncated = true },
    }))
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
    assert.equals("table", out.kind)
    assert.same({ 1, "日本語" }, out.grid.rows[1])
  end)
end)

--- `status` is the verdict, `error` is its explanation, and they arrive as two
--- fields. `redis_executor` itself emits `status: ""` with a message for an empty
--- command and it is the CLI that stamps `status = "error"` (redis_exec.rs,
--- redis_session.rs) — so the panel must read either field as the failure it is,
--- while a history entry (a whole BATCH) keeps replaying its first command's
--- result. Both directions are pinned here.
describe("poste-redis format command_failed", function()
  local function event(over)
    return vim.tbl_extend("force", {
      seq = 1, command = "SET k v", status = "ok", latency_ms = 1,
    }, over or {})
  end

  it("takes either field as the verdict", function()
    local function failed(over) return (format.command_failed(event(over))) end
    assert.is_true(failed({ status = "error" }))
    assert.is_true(failed({ status = "", error = "Empty command" }))
    assert.is_false(failed({}))
    assert.is_false((format.command_failed(nil)))
  end)

  it("does not mistake an absent message for a failure", function()
    -- `vim.NIL` is truthy in Lua; taking it as a message put a ✗ beside commands
    -- the server had answered.
    local function failed(err) return (format.command_failed(event({ error = err }))) end
    assert.is_false(failed(vim.NIL))
    assert.is_false(failed(""))
  end)

  it("renders a message-only rejection as an ERROR block", function()
    local out = format.format_result(event({ status = "", error = "Empty command",
      value = { type = "nil", value = nil } }))
    assert.equals("ERROR", out.lines[1])
    assert.truthy(table.concat(out.lines, "\n"):find("Empty command", 1, true))
  end)

  it("names a rejection that arrived without a message", function()
    -- `(nil)` is a legitimate reply the user must be able to tell apart from a
    -- rejected command; both producers pair an error with the nil placeholder.
    local out = format.format_result(event({ status = "error",
      value = { type = "nil", value = nil } }))
    assert.equals("ERROR", out.lines[1])
    assert.truthy(table.concat(out.lines, "\n"):find("(unknown error)", 1, true))
  end)

  it("keeps a batch replay on its first command's result", function()
    -- The entry's status is the batch verdict; its value belongs to the first
    -- command, which succeeded. The sidebar still marks it ✗.
    local out = format.format_result(event({ status = "error", batch = true,
      value = { type = "integer", value = 1 } }))
    assert.equals("text", out.kind)
    assert.equals("1", out.lines[1])
  end)

  it("shows the message when the batch's first command itself failed", function()
    local out = format.format_result(event({ status = "error", batch = true,
      error = "WRONGTYPE Operation against a key", value = { type = "nil" } }))
    assert.equals("ERROR", out.lines[1])
  end)

  it("marks every failed shape with the winbar cross", function()
    assert.truthy(format.status_summary(event({ status = "error" })):find("✘", 1, true))
    assert.truthy(format.status_summary(
      event({ status = "", error = "Empty command" })):find("✘", 1, true))
  end)
end)
