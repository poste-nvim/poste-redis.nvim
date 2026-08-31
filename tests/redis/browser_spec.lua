--- browser spec — key browser tree flattening + SCAN grouping (pure logic,
--- no transport: build_children/flatten/fetch_command are tested directly).
local tree = require("poste-redis.browser.tree")
local async = require("poste-redis.browser.async")
local value = require("poste-redis.browser.value")

describe("poste-redis browser tree", function()
  it("flattens a flat key list under a db node", function()
    local db = tree.make_db_node({ db = 3 }, "my-redis")
    db.children = {
      tree.make_key_node("user:1", "my-redis", 3, { type = "string" }),
      tree.make_key_node("user:2", "my-redis", 3, { type = "hash", size = "2" }),
    }
    db.expanded = true
    local lines, node_map = tree.flatten_tree({ db })
    assert.equals(3, #lines)
    assert.match("3", lines[1])          -- db node shows the db number
    assert.match("user:1", lines[2])
    assert.match("user:2", lines[3])
    assert.match("hash", lines[3])
    assert.equals(3, #node_map)
    -- flat keys are leaves: no marker
    assert.is_nil(lines[2]:match("^%s*[▸▾]"))
  end)

  it("renders collapsed/expanded markers on non-leaf nodes", function()
    local conn = tree.make_connection_node({ name = "c", url = "redis://h:6379/0", dialect = "redis" })
    local db = tree.make_db_node({ db = 0 }, "c")
    conn.children = { db }
    local lines = tree.flatten_tree({ conn })
    assert.match("▸", lines[1])
    conn.expanded = true
    db.expanded = true
    lines = tree.flatten_tree({ conn })
    assert.match("▾", lines[1])
    assert.match("▾", lines[2])
  end)

  it("maps buffer lines to nodes via get_node_at_line", function()
    local conn = tree.make_connection_node({ name = "c", url = "u", dialect = "redis" })
    local db = tree.make_db_node({ db = 1 }, "c")
    local key = tree.make_key_node("k", "c", 1)
    conn.children = { db }
    db.children = { key }
    conn.expanded = true
    db.expanded = true
    local _, node_map = tree.flatten_tree({ conn })
    assert.equals(conn, tree.get_node_at_line(node_map, 1))
    assert.equals(db, tree.get_node_at_line(node_map, 2))
    assert.equals(key, tree.get_node_at_line(node_map, 3))
    assert.is_nil(tree.get_node_at_line(node_map, 4))
  end)
end)

describe("poste-redis browser async grouping", function()
  it("builds flat children in flat view", function()
    async.tree_view = false
    local db = tree.make_db_node({ db = 0 }, "c")
    async._test.build_children(db, { "a", "b:1", "c" }, "c", 0)
    assert.equals(3, #db.children)
    assert.equals("key", db.children[1].node_type)
    assert.equals("a", db.children[1].name)
  end)

  it("buckets keys by first : segment in tree view", function()
    async.tree_view = true
    local db = tree.make_db_node({ db = 0 }, "c")
    async._test.build_children(db, { "user:1", "user:2", "cache:a", "plain" }, "c", 0)
    -- plain stays flat; user/cache become group nodes
    local groups, flat = {}, {}
    for _, ch in ipairs(db.children) do
      if ch.node_type == "group" then groups[#groups + 1] = ch
      elseif ch.node_type == "key" then flat[#flat + 1] = ch end
    end
    assert.equals(2, #groups)
    assert.equals("cache", groups[1].name)  -- sorted
    assert.equals("user", groups[2].name)
    assert.equals(2, #groups[2].children)
    assert.equals("user:1", groups[2].children[1].name)
    assert.equals(1, #flat)
    assert.equals("plain", flat[1].name)
  end)

  it("sorts group buckets alphabetically", function()
    async.tree_view = true
    local db = tree.make_db_node({ db = 0 }, "c")
    async._test.build_children(db, { "z:a", "a:x", "m:k" }, "c", 0)
    assert.equals(3, #db.children)
    assert.equals("a", db.children[1].name)
    assert.equals("m", db.children[2].name)
    assert.equals("z", db.children[3].name)
  end)

  it("keeps keys without : flat in tree view", function()
    async.tree_view = true
    local db = tree.make_db_node({ db = 0 }, "c")
    async._test.build_children(db, { "nocolon", "has:colon" }, "c", 0)
    local group_count, flat_count = 0, 0
    for _, ch in ipairs(db.children) do
      if ch.node_type == "group" then group_count = group_count + 1
      else flat_count = flat_count + 1 end
    end
    assert.equals(1, group_count)
    assert.equals(1, flat_count)
    assert.equals("nocolon", db.children[1].name)
  end)
end)

describe("poste-redis browser value page commands", function()
  it("maps each type to its first-page command", function()
    assert.same({ "GET", "k" }, value._test.page_command("k", "string"))
    assert.same({ "HSCAN", "k", "0", "COUNT", "500" }, value._test.page_command("k", "hash"))
    assert.same({ "SSCAN", "k", "0", "COUNT", "500" }, value._test.page_command("k", "set"))
    assert.same({ "ZSCAN", "k", "0", "COUNT", "500" }, value._test.page_command("k", "zset"))
    assert.same({ "LRANGE", "k", "0", "499" }, value._test.page_command("k", "list"))
    assert.same({ "XRANGE", "k", "0", "+", "COUNT", "500" }, value._test.page_command("k", "stream"))
    assert.same({ "GET", "k" }, value._test.page_command("k", "unknown"))
  end)

  it("pages continue from a cursor", function()
    assert.same({ "HSCAN", "k", "17", "COUNT", "500" }, value._test.page_command("k", "hash", "17"))
    assert.same({ "LRANGE", "k", "500", "999" }, value._test.page_command("k", "list", 500))
    assert.same({ "SSCAN", "k", "3", "COUNT", "500" }, value._test.page_command("k", "set", "3"))
  end)

  it("builds a footer with loaded/total and page hint", function()
    local f = value._test.footer(150, 10000, { cursor = "8" })
    assert.match("150 / 10000", f)
    assert.match("next page", f)
    local f2 = value._test.footer(500, 500, { cursor = "0" })
    assert.match("500 / 500", f2)
    assert.is_nil(f2:find("next page"))
    local f3 = value._test.footer(0, 0, {})
    assert.match("0", f3)
  end)
end)

describe("poste-redis browser e2e (live redis)", function()
  local url = vim.env.REDIS_TEST_URL

  local function live_available()
    if not url or url == "" then return false end
    local binary = require("poste.state").find_poste_binary()
    if not binary or vim.fn.filereadable(binary) ~= 1 then return false end
    local probe = io.popen('echo \'{"connection":"' .. url .. '","commands":[["PING"]]}\' | "' .. binary .. '" redis-exec 2>/dev/null')
    if not probe then return false end
    local out = probe:read("*a")
    probe:close()
    return out ~= nil and out:find("PONG") ~= nil
  end

  local ok_avail = live_available()

  after_each(function()
    require("poste-redis.session_conn").stop_all()
  end)

  it("scan_keys loads keys into groups via the live session", function()
    if not ok_avail then pending("REDIS_TEST_URL not reachable"); return end
    local tree = require("poste-redis.browser.tree")
    local async = require("poste-redis.browser.async")
    local session_conn = require("poste-redis.session_conn")

    -- ensure the fixture keys exist (the suite may have deleted some)
    local seeded = false
    session_conn.execute(url, {
      "MSET", "user:1", "alice", "user:2", "bob", "cache:a", "1", "plain", "x",
    }, {
      on_response = function() seeded = true end,
    }, nil, { db = 0 })
    vim.wait(3000, function() return seeded end, 5)

    async.tree_view = true
    local db = tree.make_db_node({ db = 0 }, "browser-e2e")
    local done = false
    async.scan_keys(db, url, "browser-e2e")
    -- SCAN is async; poll for loading to finish (generous window: session
    -- start + first SCAN round-trip)
    local wait_ok = vim.wait(10000, function()
      return not db.loading
    end, 10)
    assert.is_true(wait_ok, "scan did not finish in 10s")
    assert.is_true(db.children ~= nil and #db.children >= 2,
      "expected user:/cache: groups, got " .. (db.children and #db.children or "nil"))
    local names = {}
    for _, ch in ipairs(db.children) do
      if ch.node_type == "group" then
        table.insert(names, ch.name)
        assert.is_true(#ch.children >= 1)
        local k = ch.children[1]
        assert.equals("key", k.node_type)
        assert.equals(0, k.meta.db)
      end
    end
    assert.is_true(vim.tbl_contains(names, "user"))
    assert.is_true(vim.tbl_contains(names, "cache"))
  end)

  it("value.view renders a string key through the live session", function()
    if not ok_avail then pending("REDIS_TEST_URL not reachable"); return end
    local tree = require("poste-redis.browser.tree")
    local value = require("poste-redis.browser.value")
    local buffer = require("poste-redis.buffer")
    local session_conn = require("poste-redis.session_conn")

    -- self-seed (the suite may run against a clean db)
    local seeded = false
    session_conn.execute(url, { "SET", "user:1", "alice", "EX", "300" }, {
      on_response = function() seeded = true end,
    }, nil, { db = 0 })
    vim.wait(3000, function() return seeded end, 5)

    local node = tree.make_key_node("user:1", "browser-e2e", 0, { type = "string" })
    node.meta.url = url
    local done = false
    value.view(node, {}, function() done = true end)
    vim.wait(3000, function() return done end, 5)
    assert.is_true(done)
    assert.is_true(buffer.is_open())
    local lines = vim.api.nvim_buf_get_lines(buffer.buf(), 0, -1, false)
    local joined = table.concat(lines, "\n")
    assert.is_true(joined:find("alice") ~= nil, "value not rendered: " .. joined)
    buffer.close()
  end)

  it("value.view renders a hash via HSCAN with a loaded footer", function()
    if not ok_avail then pending("REDIS_TEST_URL not reachable"); return end
    local tree = require("poste-redis.browser.tree")
    local value = require("poste-redis.browser.value")
    local buffer = require("poste-redis.buffer")
    local session_conn = require("poste-redis.session_conn")

    -- self-seed hash fixture
    local seeded = false
    session_conn.execute(url, {
      "HSET", "user:3", "name", "carol", "age", "30",
    }, {
      on_response = function() seeded = true end,
    }, nil, { db = 0 })
    vim.wait(3000, function() return seeded end, 5)

    local node = tree.make_key_node("user:3", "browser-e2e", 0, { type = "hash" })
    node.meta.url = url
    local done = false
    value.view(node, {}, function() done = true end)
    vim.wait(3000, function() return done end, 5)
    assert.is_true(done)
    assert.is_true(buffer.is_open())
    local lines = vim.api.nvim_buf_get_lines(buffer.buf(), 0, -1, false)
    local joined = table.concat(lines, "\n")
    assert.is_true(joined:find("carol") ~= nil, "hash field not rendered: " .. joined)
    assert.is_true(joined:find("loaded") ~= nil, "footer missing: " .. joined)
    buffer.close()
  end)
end)

describe("poste-redis browser actions e2e (live redis)", function()
  local url = vim.env.REDIS_TEST_URL

  local function live_available()
    if not url or url == "" then return false end
    local binary = require("poste.state").find_poste_binary()
    if not binary or vim.fn.filereadable(binary) ~= 1 then return false end
    local probe = io.popen('echo \'{"connection":"' .. url .. '","commands":[["PING"]]}\' | "' .. binary .. '" redis-exec 2>/dev/null')
    if not probe then return false end
    local out = probe:read("*a")
    probe:close()
    return out ~= nil and out:find("PONG") ~= nil
  end

  local ok_avail = live_available()

  after_each(function()
    require("poste-redis.session_conn").stop_all()
  end)

  it("set_ttl persists an EXPIRE through the live session", function()
    if not ok_avail then pending("REDIS_TEST_URL not reachable"); return end
    local actions = require("poste-redis.browser.actions")
    local tree = require("poste-redis.browser.tree")
    local session_conn = require("poste-redis.session_conn")

    -- self-seed the key (suite may run against a clean db)
    local seeded = false
    session_conn.execute(url, { "SET", "act:ttl", "v", "EX", "100" }, {
      on_response = function() seeded = true end,
    }, nil, { db = 0 })
    vim.wait(3000, function() return seeded end, 5)

    -- stub the input dialog to answer 500
    local orig_input = vim.ui.input
    vim.ui.input = function(_, cb) cb("500") end

    local node = tree.make_key_node("act:ttl", "e2e", 0, { type = "string" })
    node.meta.url = url
    local done = false
    actions.set_ttl(node, {})
    vim.wait(3000, function() return done end, 5)
    -- verify via TTL query
    local ttl = nil
    session_conn.execute(url, { "TTL", "act:ttl" }, {
      on_response = function(ev) ttl = ev.value and ev.value.value end,
    })
    vim.wait(3000, function() return ttl ~= nil end, 5)
    assert.is_true(ttl ~= nil and ttl > 0 and ttl <= 500,
      "expected TTL 1..500, got " .. tostring(ttl))
    vim.ui.input = orig_input
  end)

  it("delete_key removes a key through the live session", function()
    if not ok_avail then pending("REDIS_TEST_URL not reachable"); return end
    local actions = require("poste-redis.browser.actions")
    local tree = require("poste-redis.browser.tree")
    local session_conn = require("poste-redis.session_conn")

    -- seed the key
    local seeded = false
    session_conn.execute(url, { "SET", "act:del", "v" }, {
      on_response = function() seeded = true end,
    })
    vim.wait(3000, function() return seeded end, 5)

    local orig_confirm = vim.fn.confirm
    vim.fn.confirm = function() return 1 end  -- Yes
    local node = tree.make_key_node("act:del", "e2e", 0, { type = "string" })
    node.meta.url = url
    local done = false
    actions.delete_key(node, { render = function() done = true end })
    vim.wait(3000, function() return done end, 5)
    vim.fn.confirm = orig_confirm

    -- verify gone
    local exists = nil
    session_conn.execute(url, { "EXISTS", "act:del" }, {
      on_response = function(ev) exists = ev.value and ev.value.value end,
    })
    vim.wait(3000, function() return exists ~= nil end, 5)
    assert.equals(0, exists, "key act:del should be gone")
  end)

  it("rename_key renames with EXISTS check through the live session", function()
    if not ok_avail then pending("REDIS_TEST_URL not reachable"); return end
    local actions = require("poste-redis.browser.actions")
    local tree = require("poste-redis.browser.tree")
    local session_conn = require("poste-redis.session_conn")

    -- idempotent seed: clear both names, then create act:ren
    local seeded = false
    session_conn.execute(url, { "DEL", "act:ren", "act:ren2" }, {
      on_response = function()
        session_conn.execute(url, { "SET", "act:ren", "v" }, {
          on_response = function() seeded = true end,
        })
      end,
    })
    vim.wait(3000, function() return seeded end, 5)

    local orig_input = vim.ui.input
    vim.ui.input = function(_, cb) cb("act:ren2") end
    local node = tree.make_key_node("act:ren", "e2e", 0, { type = "string" })
    node.meta.url = url
    local done = false
    actions.rename_key(node, { render = function() done = true end })
    vim.wait(3000, function() return done end, 5)
    vim.ui.input = orig_input

    -- verify new key exists, old gone
    local old_v, new_v = nil, nil
    session_conn.execute(url, { "EXISTS", "act:ren" }, {
      on_response = function(ev) old_v = ev.value and ev.value.value end,
    })
    session_conn.execute(url, { "EXISTS", "act:ren2" }, {
      on_response = function(ev) new_v = ev.value and ev.value.value end,
    })
    vim.wait(3000, function() return old_v ~= nil and new_v ~= nil end, 5)
    assert.equals(0, old_v, "old key should be gone")
    assert.equals(1, new_v, "new key should exist")

    -- cleanup
    local cleaned = false
    session_conn.execute(url, { "DEL", "act:ren2" }, {
      on_response = function() cleaned = true end,
    })
    vim.wait(3000, function() return cleaned end, 5)
  end)
end)
