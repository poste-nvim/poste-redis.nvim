--- toml spec — the vendored parser (vendored from poste-db, see file header).
local toml = require("poste-redis.toml")

describe("poste-redis toml (vendored)", function()
  it("parses sections with string, number, and bool values", function()
    local out = toml.parse([[
[my-redis]
dialect = "redis"
url = "redis://127.0.0.1:6379/0"
port = 6379
tls = false
]])
    assert.is_table(out)
    assert.equals("redis", out["my-redis"].dialect)
    assert.equals("redis://127.0.0.1:6379/0", out["my-redis"].url)
    assert.equals(6379, out["my-redis"].port)
    assert.equals(false, out["my-redis"].tls)
  end)

  it("handles comments and inline comments", function()
    local out = toml.parse([[
# leading comment
[srv]
url = "redis://h:6379/0" # trailing
host = "h"
]])
    assert.equals("redis://h:6379/0", out.srv.url)
    assert.equals("h", out.srv.host)
  end)

  it("does not treat # inside a quoted url as a comment", function()
    local out = toml.parse('url = "redis://h:6379/0#x"\n')
    assert.equals("redis://h:6379/0#x", out.url)
  end)

  it("decodes basic double-quote escapes", function()
    local out = toml.parse([[
[srv]
password = "a\"b\\c"
]])
    assert.equals('a"b\\c', out.srv.password)
  end)

  it("decodes escapes in ONE pass (an escaped backslash never forms a new escape)", function()
    -- sequential gsubs re-decode their own output: "D:\\tables\\notes" must
    -- stay backslash + 't'/'n', not collapse into TAB/newline
    local out = toml.parse('path = "D:\\\\tables\\\\notes"\n')
    assert.equals("D:\\tables\\notes", out.path)
    local pw = toml.parse('password = "a\\\\nb"\n')
    assert.equals("a\\nb", pw.password)
  end)

  it("decodes real tab/newline escapes still", function()
    local out = toml.parse('note = "a\\tb\\nc"\n')
    assert.equals("a\tb\nc", out.note)
  end)

  it("supports single-quoted literal strings", function()
    local out = toml.parse("path = 'a\\b'\n")
    assert.equals("a\\b", out.path)
  end)

  it("literal strings: a trailing backslash does not eat the closing quote", function()
    -- '…' is literal: the \ is data, so stripping 2 chars after it swallowed
    -- the closing quote and misread the rest of the line as string content
    local out = toml.parse("path = 'a\\' # trailing comment\n")
    assert.equals("a\\", out.path)
  end)

  it("double-quoted strings: an escaped quote before # still ends the string", function()
    local out = toml.parse('pw = "a\\"b" # trailing\n')
    assert.equals('a"b', out.pw)
  end)

  it("strips a UTF-8 BOM before parsing", function()
    -- editors/Windows tools save with a BOM; unparsed the first key=value
    -- line fails as invalid
    local out = toml.parse("﻿[srv]\ndialect = \"redis\"\n")
    assert.equals("redis", out.srv.dialect)
  end)

  it("unclosed-string errors never echo the value (may be a secret)", function()
    local out, err = toml.parse("password = \"s3cret-value\n")
    assert.is_nil(out)
    assert.truthy(err)
    assert.falsy(err:find("s3cret%-value", 1, false))
  end)

  it("supports true/false and top-level keys", function()
    local out = toml.parse("tls = true\nhost = \"h\"\n")
    assert.equals(true, out.tls)
    assert.equals("h", out.host)
  end)

  it("reports an unclosed string", function()
    local out, err = toml.parse('url = "redis://h:6379/0\n')
    assert.is_nil(out)
    assert.truthy(err)
  end)

  it("reports an invalid table header", function()
    local out, err = toml.parse("[unclosed\n")
    assert.is_nil(out)
    assert.truthy(err)
  end)

  it("reports an invalid key=value line", function()
    local out, err = toml.parse("[srv]\nno_equals_here\n")
    assert.is_nil(out)
    assert.truthy(err)
  end)

  it("parses a file from disk", function()
    local path = vim.fn.fnamemodify(vim.fn.tempname(), ":p") .. ".toml"
    vim.fn.writefile({ "[srv]", "dialect = \"redis\"", "url = \"redis://h:6379/0\"" }, path)
    local out, err = toml.parse_file(path)
    pcall(vim.fn.delete, path)
    assert.is_nil(err)
    assert.equals("redis", out.srv.dialect)
  end)

  it("fails cleanly on a missing file", function()
    local out, err = toml.parse_file("/nonexistent/connections.toml")
    assert.is_nil(out)
    assert.truthy(err)
  end)

  -- The shapes poste-db added after 94fccf2. A project keeps ONE
  -- connections.toml for the whole plugin family, so a redis-only install
  -- still has to read a file whose postgres sections use inline tables.
  it("parses an inline table into a real table", function()
    local out = toml.parse('[pg]\ndialect = "postgres"\ntunnel = { to = "jump@bastion", port = 2222 }')
    assert.is_table(out.pg.tunnel)
    assert.equals("jump@bastion", out.pg.tunnel.to)
    assert.equals(2222, out.pg.tunnel.port)
  end)

  it("parses inline arrays and keeps commas inside strings", function()
    local out = toml.parse('[pg]\nlist = ["a,b", "c"]\nempty = []')
    assert.same({ "a,b", "c" }, out.pg.list)
    assert.same({}, out.pg.empty)
  end)

  it("reports an unclosed inline container instead of stringifying it", function()
    local parsed, err = toml.parse('tunnel = { to = "x"')
    assert.is_nil(parsed)
    assert.equals("Unclosed inline table", err)
  end)

  it("rejects [[array-of-tables]] instead of making a \"[name\" section", function()
    local out, err = toml.parse('[[srv]]\ndialect = "redis"')
    assert.is_nil(out)
    assert.equals("Array-of-tables headers ([[name]]) are not supported", err)
  end)

  it("rejects dotted keys but keeps dotted section names", function()
    -- the header IS the connection name, so `my-app.prod` must stay legal
    local out, err = toml.parse('[my-app.prod]\ndialect = "redis"')
    assert.is_nil(err)
    assert.equals("redis", out["my-app.prod"].dialect)

    local bad, bad_err = toml.parse('[srv]\ntunnel.to = "h"')
    assert.is_nil(bad)
    assert.truthy(bad_err:find("Dotted keys", 1, true))
  end)

  it("never echoes a malformed line's value (may be a secret)", function()
    local out, err = toml.parse('password "s3cret-value"')
    assert.is_nil(out)
    assert.falsy(err:find("s3cret%-value", 1, false))
  end)
end)
