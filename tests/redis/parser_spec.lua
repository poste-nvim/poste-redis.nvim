--- Parser spec — poste-redis EXECUTION-PLAN §4.2 test matrix.
--- The parser is the only .redis parser (D1); every extraction rule here
--- gates what the binary receives.
local parser = require("poste-redis.parser")

describe("poste-redis parser", function()
  it("parses a single command line", function()
    local entries = parser.extract_entries("GET user:42\n")
    assert.equals(1, #entries)
    local e = entries[1]
    assert.equals("command", e.kind)
    assert.equals("GET", e.command)
    assert.same({ "GET", "user:42" }, e.tokens)
    assert.equals(1, e.start_line)
    assert.equals(1, e.end_line)
  end)

  it("joins continuation lines ending in backslash", function()
    local entries = parser.extract_entries(
      "HSET user:42 name \"Alice\" \\\n"
      .. "  email \"alice@example.com\" \\\n"
      .. "  age 30\n")
    assert.equals(1, #entries)
    local e = entries[1]
    assert.same({ "HSET", "user:42", "name", "\"Alice\"", "email", "\"alice@example.com\"", "age", "30" }, e.tokens)
    -- span covers all three physical lines (cursor on line 3 selects it)
    assert.equals(1, e.start_line)
    assert.equals(3, e.end_line)
  end)

  it("handles trailing whitespace after continuation backslash", function()
    local entries = parser.extract_entries("SET k v \\  \n  tail\n")
    assert.equals(1, #entries)
    assert.same({ "SET", "k", "v", "tail" }, entries[1].tokens)
  end)

  it("does not treat # inside double quotes as a comment", function()
    local entries = parser.extract_entries('SET note "a # b"\n')
    assert.equals(1, #entries)
    assert.same({ "SET", "note", "\"a # b\"" }, entries[1].tokens)
  end)

  it("does not treat # inside single quotes as a comment", function()
    local entries = parser.extract_entries("LPUSH q '{\"to\":\"a#b\"}'\n")
    assert.equals(1, #entries)
    assert.same({ "LPUSH", "q", "'{\"to\":\"a#b\"}'" }, entries[1].tokens)
  end)

  it("strips inline comments after a bare #", function()
    local entries = parser.extract_entries("GET user:42  # fetch the token\n")
    assert.equals(1, #entries)
    assert.same({ "GET", "user:42" }, entries[1].tokens)
  end)

  it("treats -- as a full-line and inline comment marker", function()
    local entries = parser.extract_entries("-- whole line\nGET user:42 -- inline\n")
    assert.equals(1, #entries)
    assert.same({ "GET", "user:42" }, entries[1].tokens)
  end)

  it("keeps single-quoted literals as one token", function()
    local entries = parser.extract_entries("LPUSH q 'hello world'\n")
    assert.equals(1, #entries)
    assert.same({ "LPUSH", "q", "'hello world'" }, entries[1].tokens)
  end)

  it("parses bare words and numbers", function()
    local entries = parser.extract_entries("ZADD board 99 alice 87 bob\n")
    assert.equals(1, #entries)
    assert.same({ "ZADD", "board", "99", "alice", "87", "bob" }, entries[1].tokens)
  end)

  it("recognizes USE as a use entry", function()
    local entries = parser.extract_entries("USE my-redis\nGET k\n")
    assert.equals(2, #entries)
    assert.equals("use", entries[1].kind)
    assert.equals("my-redis", entries[1].connection)
    assert.equals("command", entries[2].kind)
  end)

  it("recognizes a bare USE (selector prompt)", function()
    local entries = parser.extract_entries("USE\n")
    assert.equals(1, #entries)
    assert.equals("use", entries[1].kind)
    assert.is_nil(entries[1].connection)
  end)

  it("USE is case-insensitive", function()
    local entries = parser.extract_entries("use my-redis\n")
    assert.equals("use", entries[1].kind)
    assert.equals("my-redis", entries[1].connection)
  end)

  it("commands are case-insensitive and uppercased", function()
    local entries = parser.extract_entries("get k\nSeT k v\n")
    assert.equals("GET", entries[1].command)
    assert.equals("SET", entries[2].command)
  end)

  it("ignores blank lines and full-line comments", function()
    local entries = parser.extract_entries("# header\n\nGET a\n\n-- note\nGET b\n")
    assert.equals(2, #entries)
    assert.same({ "GET", "a" }, entries[1].tokens)
    assert.same({ "GET", "b" }, entries[2].tokens)
  end)

  it("empty file yields no entries", function()
    local entries = parser.extract_entries("")
    assert.equals(0, #entries)
    local entries2 = parser.extract_entries("# only comments\n\n")
    assert.equals(0, #entries2)
  end)

  it("handles CRLF line endings", function()
    local entries = parser.extract_entries("GET user:42\r\nSET k v\r\n")
    assert.equals(2, #entries)
    assert.same({ "GET", "user:42" }, entries[1].tokens)
    assert.same({ "SET", "k", "v" }, entries[2].tokens)
  end)

  it("unquotes double-quoted args with JSON escapes", function()
    local args = parser.entry_args(parser.extract_entries('SET k "a\\"b\\nc"\n')[1])
    assert.same({ "SET", "k", 'a"b\nc' }, args)
  end)

  it("unquotes single-quoted args literally", function()
    local args = parser.entry_args(parser.extract_entries("LPUSH q 'hello world'\n")[1])
    assert.same({ "LPUSH", "q", "hello world" }, args)
  end)

  it("entry_args uppercases the command name and leaves USE empty", function()
    local e = parser.extract_entries("use my-redis\n")[1]
    assert.equals(0, #parser.entry_args(e))
    local e2 = parser.extract_entries("get k\n")[1]
    assert.same({ "GET", "k" }, parser.entry_args(e2))
  end)

  it("flags dangerous commands", function()
    assert.is_true(parser.is_dangerous(parser.extract_entries("FLUSHALL\n")[1]))
    assert.is_true(parser.is_dangerous(parser.extract_entries("CONFIG SET save ''\n")[1]))
    assert.is_false(parser.is_dangerous(parser.extract_entries("SET k v\n")[1]))
    assert.is_false(parser.is_dangerous(parser.extract_entries("USE my-redis\n")[1]))
  end)

  it("continuation stops at blank lines", function()
    local entries = parser.extract_entries("SET k v \\\n\nGET a\n")
    assert.equals(2, #entries)
    assert.same({ "SET", "k", "v" }, entries[1].tokens)
    assert.same({ "GET", "a" }, entries[2].tokens)
  end)

  it("multi-line commands selectable from any spanned line", function()
    local entries = parser.extract_entries("HSET k f1 v1 \\\n  f2 v2\n")
    assert.equals(1, #entries)
    local e = entries[1]
    assert.equals(2, e.end_line)
    -- visual_entries with a range covering line 2 picks it up
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "HSET k f1 v1 \\", "  f2 v2" })
    local sel = parser.visual_entries(buf, { start_line = 2, end_line = 2 })
    assert.equals(1, #sel)
    assert.equals("HSET", sel[1].command)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("visual_entries treats zero lines as 'no range' (unset marks)", function()
    -- Lua 0 is truthy: a bare `not s_line` check let a fresh buffer's unset
    -- '< '>' marks (line 0) skip the fallback and match nothing
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "GET a" })
    assert.equals(0, #parser.visual_entries(buf, { start_line = 0, end_line = 0 }))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("uses the current connection directive until a later USE overrides it", function()
    -- no state in the parser itself; this documents that USE ordering is a
    -- caller concern (exec_run groups by connection). Just verify extraction.
    local entries = parser.extract_entries("USE a\nGET 1\nUSE b\nGET 2\n")
    assert.equals(4, #entries)
    assert.equals("a", entries[1].connection)
    assert.equals("b", entries[3].connection)
  end)
end)

describe("poste-redis parser bounded buffer_entries", function()
  it("parses only lines 1..max_line when bounded", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "USE prod",
      "SELECT 3",
      "SET k v",
      "GET k",
    })
    local bounded = parser.buffer_entries(buf, { max_line = 2 })
    assert.equals(2, #bounded)
    assert.equals("use", bounded[1].kind)
    assert.equals("SELECT", bounded[2].command)
    -- unbounded still sees everything
    assert.equals(4, #parser.buffer_entries(buf))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
