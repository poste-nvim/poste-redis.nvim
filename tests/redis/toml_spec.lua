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
end)
