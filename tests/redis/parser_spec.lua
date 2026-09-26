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

  it("re-joins a WORD split across a continuation (redis-cli semantics)", function()
    -- redis-cli lexes the whole logical line, so `DEL a-\` + `b` is ONE key
    -- `a-b`; joining token lists alone sent `DEL a- b` — deleting the two
    -- unrelated keys `a-` and `b` (a silent wrong-target write)
    local entries = parser.extract_entries("DEL a-\\\nmore\n")
    assert.equals(1, #entries)
    assert.same({ "DEL", "a-more" }, entries[1].tokens)
    assert.same({ "DEL", "a-more" }, parser.entry_args(entries[1]))
    -- a three-way split joins too
    local e3 = parser.extract_entries("GET very\\\nlong\\\nkey\n")[1]
    assert.same({ "GET", "verylongkey" }, e3.tokens)
    -- between-token continuations still work untouched
    local e2 = parser.extract_entries("SET k \\\nv\n")[1]
    assert.same({ "SET", "k", "v" }, e2.tokens)
    -- a quoted chunk does NOT merge (its quote never closed) — the split
    -- stays visible in the tokens
    local eq = parser.extract_entries('SET k "va\\\nlue"\n')[1]
    assert.same({ "SET", "k", '"va', 'lue"' }, eq.tokens)
  end)

  it("keeps the open word across an empty continuation line", function()
    -- `DEL a-\` + a bare `\` line + `b`: the empty chunk used to reset the
    -- open-word flag, so `b` arrived as a second token — `DEL a- b`, the
    -- two-key wrong-target write the re-join exists to prevent
    local entries = parser.extract_entries("DEL a-\\\n\\\nb\n")
    assert.equals(1, #entries)
    assert.same({ "DEL", "a-b" }, entries[1].tokens)
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

  it("keeps a # glued to a word part of the word — a key, not a comment", function()
    -- redis keys are binary-safe: `user#1` is one key. The comment starter
    -- must sit at a word boundary (whitespace before it), matching the
    -- syntax file's `\s\+#` highlight rule; mid-word it silently retargeted
    -- the command — `SET user#1 v` ran as `SET user v`.
    local entries = parser.extract_entries("SET user#1 v\n")
    assert.equals(1, #entries)
    assert.same({ "SET", "user#1", "v" }, entries[1].tokens)
  end)

  it("keeps a -- glued to a word part of the word", function()
    local entries = parser.extract_entries("GET hash--tag\n")
    assert.equals(1, #entries)
    assert.same({ "GET", "hash--tag" }, entries[1].tokens)
  end)

  it("a key that itself starts with -- still needs quoting", function()
    local entries = parser.extract_entries('GET "--key"\n')
    assert.equals(1, #entries)
    assert.same({ "GET", "--key" }, parser.entry_args(entries[1]))
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

  it("decodes escaped backslashes in ONE pass (JSON \\\\n is backslash + n)", function()
    -- sequential gsub passes turned `\\n` into a newline after `\\` → `\`;
    -- per JSON it must stay the literal two characters backslash + n
    local args = parser.entry_args(parser.extract_entries('SET k "a\\\\nb"\n')[1])
    assert.same({ "SET", "k", "a\\nb" }, args)
    -- the plain escapes still decode
    local args2 = parser.entry_args(parser.extract_entries('SET k "x\\ty"\n')[1])
    assert.same({ "SET", "k", "x\ty" }, args2)
  end)

  it("decodes hex byte escapes in double quotes (redis-cli parity)", function()
    -- redis-cli's sdssplitargs accepts \xHH; without it `SET k "\x41"`
    -- wrote the FIVE literal characters backslash x 4 1 instead of "A"
    local args = parser.entry_args(parser.extract_entries('SET k "\\x41"\n')[1])
    assert.same({ "SET", "k", "A" }, args)
    -- binary-safe names: non-UTF-8 bytes reach the server as themselves
    local args2 = parser.entry_args(parser.extract_entries('GET "\\xff\\x00"\n')[1])
    assert.same({ "GET", "\xff\x00" }, args2)
    -- malformed hex keeps its characters verbatim
    local args3 = parser.entry_args(parser.extract_entries('SET k "\\xzz"\n')[1])
    assert.same({ "SET", "k", "\\xzz" }, args3)
    -- truncated escape at the end of the token stays verbatim too
    local args5 = parser.entry_args(parser.extract_entries('SET k "a\\x"\n')[1])
    assert.same({ "SET", "k", "a\\x" }, args5)
  end)

  it("decodes an escaped backslash in ONE pass (\\\\x41 is not A)", function()
    -- sequential gsub passes would decode the \x41 after the \\. The single
    -- pass must turn `a\\x41b` into backslash + x + 4 + 1, not "aAb"
    local args = parser.entry_args(parser.extract_entries('SET k "a\\\\x41b"\n')[1])
    assert.same({ "SET", "k", "a\\x41b" }, args)
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

  it("decodes a quoted command head everywhere the name is interpreted", function()
    -- the blacklist must not be escapable by typing the name in quotes, and the
    -- server is sent the bare name anyway (`"FLUSHALL"` is not a command to it)
    local quoted = parser.extract_entries('"FLUSHALL"\n')[1]
    assert.equals("FLUSHALL", quoted.command)
    assert.is_true(parser.is_dangerous(quoted))
    assert.same({ "FLUSHALL" }, parser.entry_args(quoted))
    assert.equals("SET", parser.extract_entries("'set' k v\n")[1].command)
    -- `raw` keeps the text as written, so the panel title is not rewritten
    assert.equals('"FLUSHALL"', quoted.raw)
  end)

  it("decodes a quoted USE so the connection name resolves", function()
    local e = parser.extract_entries('USE "local"\n')[1]
    assert.equals("use", e.kind)
    assert.equals("local", e.connection)
    -- quoting the verb is equally a USE directive
    assert.equals("use", parser.extract_entries('"use" local\n')[1].kind)
    assert.same({ "SET", "k", "v" }, parser.command_tokens('"SET" "k" "v"'))
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

describe("poste-redis parser key_arg", function()
  local function key_of(line)
    local tokens = parser.command_tokens(line)
    return parser.key_arg(tokens)
  end

  it("returns the key for commands whose second token IS the key", function()
    assert.equals("user:1", key_of("GET user:1"))
    assert.equals("session", key_of("HSET session user lex"))
    assert.equals("board", key_of("ZADD board 99 alice"))
    -- the SCAN family that leads with the key stays addressable; only the
    -- cursor-first variants are wrong
    assert.equals("user:1", key_of("HSCAN user:1 0 MATCH name* COUNT 10"))
    assert.equals("user:1", key_of("SSCAN user:1 0"))
    assert.equals("user:1", key_of("ZSCAN user:1 0"))
    assert.equals("q", key_of("BLPOP q 5"))
    assert.equals("s", key_of("XRANGE s - + COUNT 10"))
    assert.equals("s", key_of("XACK s mygroup 1-1"))
    assert.equals("a", key_of("COPY a b"))
    assert.equals("mylist", key_of("SORT mylist BY w* DESC"))
  end)

  it("does not treat a cursor or a glob as a key", function()
    -- SCAN's second token is a cursor and KEYS' is a pattern; both used to be
    -- revealed as key names and probed with `TTL 0` / `TTL users:*`
    assert.is_nil(key_of("SCAN 0 MATCH users:* COUNT 100"))
    assert.is_nil(key_of("SCAN 123456"))
    assert.is_nil(key_of("KEYS users:*"))
  end)

  it("does not treat a script body or function name as a key", function()
    -- the whole Lua source ends up as the second token; revealing it points the
    -- tree at text that is not a key, and the TTL probe sends it as one
    assert.is_nil(key_of('EVAL "return redis.call(\'GET\', KEYS[1])" 1 user:1'))
    assert.is_nil(key_of("EVALSHA 758b5c81f4 1 user:1"))
    assert.is_nil(key_of("FCALL myfunc 1 user:1"))
    assert.is_nil(key_of("FCALL_RO myfunc 1 user:1"))
  end)

  it("does not treat a pubsub channel as a key", function()
    -- channels live in a different namespace from keys, so the tree has nothing
    -- to reveal
    assert.is_nil(key_of("SUBSCRIBE news"))
    assert.is_nil(key_of("UNSUBSCRIBE news"))
    assert.is_nil(key_of("PSUBSCRIBE news.*"))
    assert.is_nil(key_of("PUNSUBSCRIBE news.*"))
    assert.is_nil(key_of("SSUBSCRIBE news"))
    assert.is_nil(key_of("SUNSUBSCRIBE news"))
    assert.is_nil(key_of("PUBLISH news hello"))
    assert.is_nil(key_of("PUBSUB CHANNELS"))
  end)

  it("does not treat a reader option or a key count as a key", function()
    assert.is_nil(key_of("XREAD BLOCK 0 STREAMS s 0"))
    assert.is_nil(key_of("XREADGROUP GROUP g c STREAMS s >"))
    assert.is_nil(key_of("LMPOP 1 mylist LEFT"))
    assert.is_nil(key_of("ZMPOP 1 myzset LEFT"))
    assert.is_nil(key_of("SINTERCARD 2 a b"))
  end)

  it("does not treat server-scope, connection or admin arguments as a key", function()
    assert.is_nil(key_of("CLUSTER KEYSLOT user:1"))
    assert.is_nil(key_of("MODULE LOAD /etc/redis/extra.so"))
    assert.is_nil(key_of("INFO keyspace"))
    assert.is_nil(key_of("DEBUG SET-ACTIVE-EXPIRE 1"))
    assert.is_nil(key_of("SWAPDB 0 1"))
    assert.is_nil(key_of("MIGRATE host 6379 user:1 0 5000"))
    assert.is_nil(key_of("WAIT 1 5000"))
    assert.is_nil(key_of("WAITAOF 1 1 5000"))
    assert.is_nil(key_of("HELLO 3"))
    -- AUTH's second token is a username and its third a password; echoing
    -- either into the tree or a TTL probe would leak it into a visible name
    assert.is_nil(key_of("AUTH admin s3cret"))
    -- PING/ECHO's argument is a message: key_arg sent it to the server as a
    -- key name (gd reveal + the winbar TTL probe both read it)
    assert.is_nil(key_of("PING"))
    assert.is_nil(key_of("PING 'hello world'"))
    assert.is_nil(key_of("ECHO message"))
  end)

  it("has no key for one-word commands and cannot be escaped by quoting", function()
    assert.is_nil(key_of("RANDOMKEY"))
    assert.is_nil(key_of("DBSIZE"))
    assert.is_nil(key_of("SCAN"))
    -- command_tokens decodes and uppercases the head, so the denylist is keyed
    -- on the real name: `"scan"` is the same command to the server anyway
    assert.is_nil(key_of('"scan" 0 MATCH users:*'))
    assert.is_nil(key_of("'auth' admin s3cret"))
    assert.is_nil(key_of('"EVAL" "return 1" 0'))
  end)

  it("tolerates missing input", function()
    assert.is_nil(parser.key_arg(nil))
    assert.is_nil(parser.key_arg({}))
    assert.is_nil(parser.key_arg({ "GET" }))
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
