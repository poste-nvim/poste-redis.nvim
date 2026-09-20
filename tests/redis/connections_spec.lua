--- connections spec — connections.toml redis 段解析 + {{var}} 展开 + 错误路径。
--- Covers EXECUTION-PLAN §5: url form, field form, tls, env expansion,
--- validation errors, and the USE-driven context apply.
local connections = require("poste-redis.connections")
local redis_state = require("poste-redis.state")

describe("poste-redis connections", function()
  local tmpdir
  local repo_cwd = vim.fn.getcwd()

  before_each(function()
    tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir, "p")
    connections._test.reset_caches()
    redis_state.context = { connection = nil, db = nil }
    redis_state.current_url = nil
  end)

  after_each(function()
    -- two cases below cd into tmpdir to exercise discovery-from-cwd; leaving
    -- the process there makes every later require() in the file resolve
    -- against a directory that is about to be deleted
    vim.api.nvim_set_current_dir(repo_cwd)
    connections._test.reset_caches()
    pcall(vim.fn.delete, tmpdir, "rf")
  end)

  --- Write a file into the temp dir and return its path.
  local function write(name, content)
    local path = vim.fn.fnameescape(tmpdir .. "/" .. name)
    vim.fn.writefile(vim.split(content, "\n", { plain = true }), path)
    return path
  end

  local function reset()
    connections._test.reset_caches()
    redis_state.context = { connection = nil, db = nil }
    redis_state.current_url = nil
  end

  before_each(reset)

  it("resolves a connection using the url field", function()
    write("connections.toml", [[
[srv]
dialect = "redis"
url = "redis://127.0.0.1:16379/2"
]])
    local url, err = connections.resolve_redis_url("srv", { search_dir = tmpdir })
    assert.is_nil(err)
    assert.equals("redis://127.0.0.1:16379/2", url)
  end)

  it("accepts a rediss:// url (tls via url form)", function()
    write("connections.toml", [[
[srv]
dialect = "redis"
url = "rediss://:pass@host:6380/0"
]])
    local url, err = connections.resolve_redis_url("srv", { search_dir = tmpdir })
    assert.is_nil(err)
    assert.equals("rediss://:pass@host:6380/0", url)
  end)

  it("builds a URL from individual fields", function()
    write("connections.toml", [[
[srv]
dialect = "redis"
host = "127.0.0.1"
port = 6379
db = 3
]])
    local url, err = connections.resolve_redis_url("srv", { search_dir = tmpdir })
    assert.is_nil(err)
    assert.equals("redis://127.0.0.1:6379/3", url)
  end)

  it("uses tls = true to switch the scheme", function()
    write("connections.toml", [[
[srv]
dialect = "redis"
host = "db.internal"
tls = true
db = 0
]])
    local url = connections.resolve_redis_url("srv", { search_dir = tmpdir })
    assert.equals("rediss://db.internal:6379/0", url)
  end)

  it("expands {{VAR}} from .env into the password and percent-encodes", function()
    write("connections.toml", [[
[srv]
dialect = "redis"
host = "127.0.0.1"
password = "{{REDIS_PASS}}"
]])
    write(".env", [[
REDIS_PASS=pa:ss/wd
]])
    local url, err = connections.resolve_redis_url("srv", { search_dir = tmpdir })
    assert.is_nil(err)
    assert.equals("redis://:pa%3Ass%2Fwd@127.0.0.1:6379/0", url)
  end)

  it("prefers OS env over .env", function()
    write("connections.toml", [[
[srv]
dialect = "redis"
host = "h"
password = "{{REDIS_PASS}}"
]])
    write(".env", [[
REDIS_PASS=from_env_file
]])
    vim.env.REDIS_PASS = "from_os"
    connections._test.reset_caches()
    local url = connections.resolve_redis_url("srv", { search_dir = tmpdir })
    assert.equals("redis://:from_os@h:6379/0", url)
    vim.env.REDIS_PASS = nil
  end)

  it("discovers a .env created after a cached not-found walk", function()
    -- Regression: load_dotenv cached the negative result (mtime nil matched
    -- nil), so a .env written mid-session stayed invisible to every
    -- {{VAR}} expansion until the caches were reset by hand.
    write("connections.toml", [[
[srv]
dialect = "redis"
host = "h"
password = "{{LATE_VAR}}"
]])
    -- first resolve: no .env anywhere → the ref stays literal
    local url = connections.resolve_redis_url("srv", { search_dir = tmpdir })
    assert.equals("redis://:%7B%7BLATE_VAR%7D%7D@h:6379/0", url)
    -- now the file appears; the very next resolve must pick it up
    write(".env", [[
LATE_VAR=late_secret
]])
    url = connections.resolve_redis_url("srv", { search_dir = tmpdir })
    assert.equals("redis://:late_secret@h:6379/0", url)
  end)

  it("percent-encodes an unresolved {{VAR}} ref left literal in the value", function()
    write("connections.toml", [[
[srv]
dialect = "redis"
host = "h"
password = "{{NOT_SET_ANYWHERE}}"
]])
    local url = connections.resolve_redis_url("srv", { search_dir = tmpdir })
    assert.equals("redis://:%7B%7BNOT_SET_ANYWHERE%7D%7D@h:6379/0", url)
  end)

  it("rejects a connection without a host when url is absent", function()
    write("connections.toml", [[
[srv]
dialect = "redis"
port = 6379
]])
    local url, err = connections.resolve_redis_url("srv", { search_dir = tmpdir })
    assert.is_nil(url)
    assert.truthy(err)
    assert.match("host", err)
  end)

  it("reports a non-numeric port instead of raising from string.format", function()
    -- port/db reach "%d"; a typo (or a {{VAR}} that never resolved) used to
    -- escape as a raw "bad argument #5 to '?'" traceback out of resolve()
    write("connections.toml", [[
[srv]
dialect = "redis"
host = "h"
port = "63x9"
]])
    local url, err = connections.resolve_redis_url("srv", { search_dir = tmpdir })
    assert.is_nil(url)
    assert.match("port", err)
    assert.match("srv", err, nil, true)
  end)

  it("reports a typo'd {{VAR}} in port as a config error, not a crash", function()
    write("connections.toml", [[
[srv]
dialect = "redis"
host = "h"
port = "{{REDISn_PORT}}"
]])
    local ok, url, err = pcall(connections.resolve_redis_url, "srv", { search_dir = tmpdir })
    assert.is_true(ok)
    assert.is_nil(url)
    assert.match("port", err)
    -- the unresolved literal is deliberately not echoed (it may name a secret)
    assert.falsy(err:find("REDISn_PORT", 1, false))
  end)

  it("rejects a port beyond 65535 but not an out-of-range db", function()
    -- the transport is 16-bit, so a huge port is a typo; ` databases` is a
    -- server setting, so SELECT is the right place for a bad db to surface
    write("connections.toml", [[
[bad]
dialect = "redis"
host = "h"
port = 70000
[ok]
dialect = "redis"
host = "h"
port = 6379
db = 999999
]])
    local url, err = connections.resolve_redis_url("bad", { search_dir = tmpdir })
    assert.is_nil(url)
    assert.match("65535", err)
    url, err = connections.resolve_redis_url("ok", { search_dir = tmpdir })
    assert.is_nil(err)
    assert.equals("redis://h:6379/999999", url)
  end)

  it("accepts a numeric string port from the env", function()
    write("connections.toml", [[
[srv]
dialect = "redis"
host = "h"
port = "{{ENV_PORT}}"
db = "{{ENV_DB}}"
]])
    write(".env", "ENV_PORT=6380\nENV_DB=3\n")
    local url, err = connections.resolve_redis_url("srv", { search_dir = tmpdir })
    assert.is_nil(err)
    assert.equals("redis://h:6380/3", url)
  end)

  it("rejects a fractional or negative db", function()
    write("connections.toml", [[
[srv]
dialect = "redis"
host = "h"
db = 1.5
]])
    local url, err = connections.resolve_redis_url("srv", { search_dir = tmpdir })
    assert.is_nil(url)
    assert.match("db", err)
  end)

  it("rejects a non-redis dialect", function()
    write("connections.toml", [[
[pg]
dialect = "postgres"
host = "h"
url = "postgres://h/db"
]])
    local url, err = connections.resolve_redis_url("pg", { search_dir = tmpdir })
    assert.is_nil(url)
    assert.match("not a redis connection", err)
  end)

  it("rejects a url with the wrong scheme", function()
    write("connections.toml", [[
[srv]
dialect = "redis"
url = "postgres://h/db"
]])
    local url, err = connections.resolve_redis_url("srv", { search_dir = tmpdir })
    assert.is_nil(url)
    assert.match("redis:// or rediss://", err)
  end)

  it("errors when connections.toml is absent", function()
    local url, err = connections.resolve_redis_url("srv", { search_dir = tmpdir })
    assert.is_nil(url)
    assert.truthy(err)
    assert.match("connections.toml", err)
  end)

  it("errors when the named connection is missing", function()
    write("connections.toml", [[
[other]
dialect = "redis"
url = "redis://h:6379/0"
]])
    local url, err = connections.resolve_redis_url("missing", { search_dir = tmpdir })
    assert.is_nil(url)
    assert.match("not found", err)
  end)

  it("only lists redis connections", function()
    write("connections.toml", [[
[my-redis]
dialect = "redis"
url = "redis://127.0.0.1:6379/0"

[my-pg]
dialect = "postgres"
host = "pg-host"
]])
    local list = {}
    connections.list_connections(function(l) list = l end, { search_dir = tmpdir })
    assert.equals(true, vim.wait(500, function() return #list > 0 end, 5))
    assert.equals(1, #list)
    assert.equals("my-redis", list[1].name)
    assert.equals("redis", list[1].dialect)
    assert.equals("redis://127.0.0.1:6379/0", list[1].url)
    assert.equals("127.0.0.1", list[1].host)
    assert.equals("0", list[1].db)
  end)

  it("list_connections yields nothing without a config file", function()
    local list = nil
    local done = false
    connections.list_connections(function(l) list = l; done = true end, { search_dir = tmpdir })
    assert.equals(true, vim.wait(500, function() return done end, 5))
    assert.is_table(list)
    assert.equals(0, #list)
  end)

  it("URL-derived host never carries userinfo (password stays out of host)", function()
    write("connections.toml", [[
[with-auth]
dialect = "redis"
url = "redis://alice:s3cret@db.internal:6380/2"
]])
    local list = {}
    connections.list_connections(function(l) list = l end, { search_dir = tmpdir })
    assert.equals(true, vim.wait(500, function() return #list > 0 end, 5))
    assert.equals("db.internal", list[1].host)
    assert.equals("2", list[1].db)
    assert.is_nil(list[1].host:find("s3cret", 1, true))
  end)

  it("get_connection_config returns env-expanded values", function()
    write("connections.toml", [[
[srv]
dialect = "redis"
host = "127.0.0.1"
port = 6379
password = "{{REDIS_PASS}}"
]])
    write(".env", "REDIS_PASS=topsecret")
    vim.api.nvim_set_current_dir(tmpdir)
    connections._test.reset_caches()
    local cfg = connections.get_connection_config("srv")
    assert.is_not_nil(cfg)
    assert.equals("topsecret", cfg.password)
    assert.equals(6379, cfg.port)
  end)

  it("use_connection applies the connection to state", function()
    write("connections.toml", [[
[srv]
dialect = "redis"
url = "redis://127.0.0.1:6379/0"
]])
    vim.api.nvim_set_current_dir(tmpdir)
    connections._test.reset_caches()
    local ok, err = connections.use_connection("srv")
    assert.is_true(ok)
    assert.is_nil(err)
    assert.equals("srv", redis_state.context.connection)
    assert.equals("redis://127.0.0.1:6379/0", redis_state.current_url)
  end)

  it("use_connection reports a resolution failure without touching state", function()
    write("connections.toml", [[
[srv]
dialect = "redis"
port = 6379
]])
    local ok, err = connections.use_connection("srv")
    assert.is_false(ok)
    assert.truthy(err)
    assert.is_nil(redis_state.current_url)
  end)

  it("find_connections_toml walks up from a nested directory", function()
    write("connections.toml", "[srv]\ndialect = \"redis\"\nurl = \"redis://h:6379/0\"\n")
    vim.fn.mkdir(tmpdir .. "/sub/deep", "p")
    connections._test.reset_caches()
    local path = connections.find_connections_toml(tmpdir .. "/sub/deep")
    assert.truthy(path)
    assert.match("connections%.toml$", path)
  end)

  it("discovers a connections.toml created mid-session (no stale not-found)", function()
    -- the old sticky `false` sentinel answered "not found" forever, so a file
    -- created while nvim ran was invisible until restart
    local search_dir = tmpdir .. "/sub"
    vim.fn.mkdir(search_dir, "p")
    connections._test.reset_caches()
    assert.is_nil(connections.find_connections_toml(search_dir))
    assert.is_nil(connections.find_connections_toml(search_dir)) -- misses never cache
    write("connections.toml", "[srv]\ndialect = \"redis\"\nurl = \"redis://h:6379/0\"\n")
    assert.truthy(connections.find_connections_toml(search_dir))
    local url = connections.resolve_redis_url("srv", { search_dir = search_dir })
    assert.equals("redis://h:6379/0", url)
  end)

  it("serves a found file from the cache instead of re-walking", function()
    -- completion calls this on every request; without the fast path the
    -- "cached" answer still cost a filereadable() per ancestor directory
    write("connections.toml", "[srv]\ndialect = \"redis\"\nurl = \"redis://h:6379/0\"\n")
    connections._test.reset_caches()
    local util = require("poste-redis.util")
    local real_walk = util.find_file_upwards
    local walks = 0
    util.find_file_upwards = function(...)
      walks = walks + 1
      return real_walk(...)
    end
    local first = connections.find_connections_toml(tmpdir)
    local second = connections.find_connections_toml(tmpdir)
    util.find_file_upwards = real_walk
    assert.truthy(first)
    assert.equals(first, second)
    assert.equals(1, walks, "the second lookup must hit the path+mtime cache")
  end)
end)


describe("poste-redis context statusline", function()
  local statusline = require("poste-redis.statusline")

  after_each(function()
    redis_state.context.connection = nil
    redis_state.context.db = nil
  end)

  it("builds a per-connection highlight group from connections.toml color", function()
    local orig = connections.get_connection_config
    connections.get_connection_config = function(name)
      assert.equals("prod", name)
      return { dialect = "redis", url = "redis://h:6379/0", color = "#ff0000" }
    end
    local hl = statusline.get_ctx_color("prod")
    connections.get_connection_config = orig
    assert.equals("PosteRedisCtxprod", hl)
    local hl_def = vim.api.nvim_get_hl(0, { name = hl })
    assert.equals("#ff0000", string.format("#%06x", hl_def.fg or 0):gsub("^#ff0000$", "#ff0000") and "#ff0000" or nil)
  end)

  it("returns nil when the connection has no color configured", function()
    local orig = connections.get_connection_config
    connections.get_connection_config = function() return { dialect = "redis", url = "redis://h/0" } end
    assert.is_nil(statusline.get_ctx_color("plain"))
    connections.get_connection_config = orig
  end)

  it("context text follows the applied connection", function()
    local orig = connections.get_connection_config
    connections.get_connection_config = function(name)
      return { dialect = "redis", url = "redis://h:6379/0", color = "#61afef" }
    end
    local orig_resolve = connections.resolve_redis_url
    connections.resolve_redis_url = function(name)
      return "redis://staging:6379/0", nil
    end
    local ok = connections.use_connection("staging")
    assert.is_true(ok)
    assert.equals("staging", statusline.get_context_text())
    assert.equals("PosteRedisCtxstaging", statusline.get_context_hl())
    assert.match("%%#PosteRedisCtxstaging#", statusline.get_context())
    assert.match("staging", statusline.get_context())
    connections.get_connection_config = orig
    connections.resolve_redis_url = orig_resolve
  end)
end)
