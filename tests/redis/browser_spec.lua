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
    -- flat keys nested under a db are leaves: no marker (nerd-font glyphs,
    -- written as Lua escapes so the bytes stay reviewable: f105 collapsed,
    -- f107 expanded)
    assert.is_nil(lines[2]:match("^%s*\239\132\133"))
    assert.is_nil(lines[2]:match("^%s*\239\132\135"))
  end)

  it("renders no marker on keys, even at the tree top level", function()
    local db = tree.make_db_node({ db = 0 }, "c")
    db.children = {
      tree.make_key_node("big-value", "c", 0),
      tree.make_key_node("plain", "c", 0),
    }
    db.expanded = true
    tree.display_root = db
    local lines, node_map = tree.flatten_tree({ db })
    tree.display_root = nil
    assert.equals(2, #lines)
    for i, line in ipairs(lines) do
      -- leaves show only their icon: no expand cue to mislead the user
      assert.is_nil(line:match("\239\132\133"), "line " .. i .. " got a collapsed marker")
      assert.is_nil(line:match("\239\132\135"), "line " .. i .. " got an expanded marker")
    end
    assert.equals("big-value", node_map[1].name)
  end)

  it("renders collapsed/expanded markers on non-leaf nodes", function()
    local conn = tree.make_connection_node({ name = "c", url = "redis://h:6379/0", dialect = "redis" })
    local db = tree.make_db_node({ db = 0 }, "c")
    conn.children = { db }
    local lines = tree.flatten_tree({ conn })
    assert.match("\239\132\133", lines[1])          -- f105 collapsed marker
    conn.expanded = true
    db.expanded = true
    lines = tree.flatten_tree({ conn })
    assert.match("\239\132\135", lines[1])          -- f107 expanded marker
    assert.match("\239\132\135", lines[2])
  end)

  it("maps buffer lines to nodes via get_node_at_line (3 header lines offset)", function()
    local conn = tree.make_connection_node({ name = "c", url = "u", dialect = "redis" })
    local db = tree.make_db_node({ db = 1 }, "c")
    local key = tree.make_key_node("k", "c", 1)
    conn.children = { db }
    db.children = { key }
    conn.expanded = true
    db.expanded = true
    local _, node_map = tree.flatten_tree({ conn })
    -- HEADER_LINES = 3: search bar (1) + db select (2) + separator (3),
    -- nodes start at line 4
    assert.is_nil(tree.get_node_at_line(node_map, 1))
    assert.is_nil(tree.get_node_at_line(node_map, 2))
    assert.is_nil(tree.get_node_at_line(node_map, 3))
    assert.equals(conn, tree.get_node_at_line(node_map, 4))
    assert.equals(db, tree.get_node_at_line(node_map, 5))
    assert.equals(key, tree.get_node_at_line(node_map, 6))
    assert.is_nil(tree.get_node_at_line(node_map, 7))
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

  it("load_connections keeps only redis-dialect entries", function()
    local connections = require("poste-redis.connections")
    local orig = connections.list_connections
    connections.list_connections = function(cb)
      cb({
        { name = "local",  dialect = "redis",    url = "redis://127.0.0.1:16479/0" },
        { name = "mypg",   dialect = "postgres", url = "postgres://h:5432/db" },
      })
    end
    local nodes
    async.load_connections(function(n) nodes = n end)
    connections.list_connections = orig
    assert.equals(1, #nodes)
    assert.equals("local", nodes[1].name)
    assert.equals("connection", nodes[1].node_type)
    assert.match("redis://127.0.0.1:16479", nodes[1].meta.url)
  end)

  it("search results REPLACE the tree: kept outside the db node's children", function()
    local session_conn = require("poste-redis.session_conn")
    local orig_execute = session_conn.execute
    session_conn.execute = function(conn_url, cmd, cbs)
      if cbs and cbs.on_response then
        cbs.on_response({ value = { value = { "cache:a", "cache:b" }, cursor = "0" } })
      end
      return "dispatched"
    end

    local db = tree.make_db_node({ db = 0 }, "c")
    db.children = { tree.make_group_node("user", "c", 0) }
    async.search(db, "redis://h", "c", "cache")

    -- results live on _search_results, never spliced into the db children
    assert.is_truthy(db._search_results)
    local results = db._search_results
    assert.equals("cache", results.name)
    assert.equals(2, #results.children)
    assert.equals("cache:a", results.children[1].name)
    assert.equals("cache:b", results.children[2].name)
    assert.equals(1, #db.children)
    assert.equals("user", db.children[1].name)

    -- as display root the results render at the top with no extra header line
    tree.display_root = results
    local lines, node_map = tree.flatten_tree({ results })
    tree.display_root = nil
    assert.equals(2, #lines)
    assert.match("cache:a", lines[1])
    assert.match("cache:b", lines[2])
    assert.equals(results, node_map[1].parent)

    async.search_clear(db)
    assert.is_nil(db._search_results)
    assert.equals(1, #db.children)
    assert.equals("user", db.children[1].name)

    session_conn.execute = orig_execute
  end)
end)

describe("poste-redis browser search bar", function()
  local browser = require("poste-redis.browser.init")
  local prefix = tree.SEARCH_PREFIX

  it("keeps the hint out of the query: prefix + tail parsing", function()
    assert.equals("", browser._test.parse_search_line(prefix))
    assert.equals("", browser._test.parse_search_line(prefix .. "   "))
    assert.equals("sear", browser._test.parse_search_line(prefix .. "sear"))
    assert.equals("cache:a", browser._test.parse_search_line(prefix .. "cache:a  "))
    -- prompt remnants can never become the query — only the tail counts
    assert.equals("", browser._test.parse_search_line(""))
    assert.equals("sear", browser._test.parse_search_line("sear"))
  end)

  it("search line is icon + query; hint is virt text, never buffer text", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "", "", "" })

    tree.render_search_line(buf, "")
    assert.equals(prefix, vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1],
      "empty state: the 'filter by key' hint must not be buffer text")

    tree.render_search_line(buf, "cache")
    assert.equals(prefix .. "cache", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1],
      "committed query stays on the search line")

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("separator rule lands under the db select (3 header lines)", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local sep = browser._test.separator_text()
    assert.truthy(sep:find("^%-+$"), "separator is a dash rule")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { prefix, "[ db 0]", sep })
    assert.match("^%-+$", vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1])
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

describe("poste-redis browser window", function()
  it("opens in a right-hand split without replacing the source buffer", function()
    local browser = require("poste-redis.browser.init")
    local orig_load = async.load_connections
    local orig_render_hook = async.render_hook
    async.load_connections = function(cb) cb({}) end

    local source = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(source, "browser-source.redis")
    vim.api.nvim_set_current_buf(source)
    local wins_before = #vim.api.nvim_list_wins()

    local ok, err = pcall(function() browser.open() end)
    assert.is_true(ok, tostring(err))
    assert.equals(wins_before + 1, #vim.api.nvim_list_wins())
    assert.is_true(vim.fn.bufwinid(source) ~= -1, "source buffer was replaced")

    local browser_buf = browser.info().buffer
    local source_win = vim.fn.bufwinid(source)
    local browser_win = vim.fn.bufwinid(browser_buf)
    assert.is_true(source_win ~= -1 and browser_win ~= -1)
    local source_pos = vim.api.nvim_win_get_position(source_win)
    local browser_pos = vim.api.nvim_win_get_position(browser_win)
    assert.is_true(browser_pos[2] > source_pos[2], "browser should be to the right")

    browser.close()
    async.load_connections = orig_load
    async.render_hook = orig_render_hook
    pcall(vim.api.nvim_buf_delete, source, { force = true })
  end)

  it("<leader>/ search replaces the tree; committed query stays on the bar", function()
    local browser = require("poste-redis.browser.init")
    local session_conn = require("poste-redis.session_conn")
    local prefix = tree.SEARCH_PREFIX

    local orig_load = async.load_connections
    local orig_execute = session_conn.execute
    async.load_connections = function(cb)
      cb({ tree.make_connection_node({
        name = "stub", url = "redis://127.0.0.1:16479/0", dialect = "redis",
      }) })
    end
    -- SCAN without MATCH → whole db; MATCH user* → the search hits
    session_conn.execute = function(conn_url, cmd, cbs)
      if cbs and cbs.on_response then
        local keys
        if vim.tbl_contains(cmd, "MATCH") then
          keys = { "user:1", "user:2" }
        else
          keys = { "user:1", "user:2", "plain" }
        end
        cbs.on_response({ value = { value = keys, cursor = "0" } })
      end
      return "dispatched"
    end

    local ok, err = pcall(function() browser.open() end)
    assert.is_true(ok, tostring(err))
    local buf = browser.info().buffer
    assert.is_true(vim.wait(2000, function()
      return #vim.api.nvim_buf_get_lines(buf, 0, -1, false) > 3
    end, 5), "db scan did not render")

    -- idle state: icon-only search bar (hint is virt text), db select, rule
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.equals(prefix, lines[1])
    assert.match("db 0%]", lines[2])  -- glyph-agnostic: icon sits before "db"
    assert.match("^%-+$", lines[3])
    local joined = table.concat(lines, "\n")
    assert.is_true(joined:find("plain", 1, true) ~= nil, "unfiltered tree missing")

    -- type into the bar: prefix + query only, then commit
    browser._test.search_enter()
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { prefix .. "user" })
    browser._test.search_commit()

    -- matched keys REPLACE the tree — no unfiltered rows survive
    lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    joined = table.concat(lines, "\n")
    assert.is_true(joined:find("user:1", 1, true) ~= nil, "match missing")
    assert.is_true(joined:find("user:2", 1, true) ~= nil, "match missing")
    assert.is_nil(joined:find("plain", 1, true), "search appended instead of replacing")
    assert.equals(prefix .. "user", lines[1], "committed query must stay on the bar")

    -- clear restores the unfiltered tree
    browser.search_clear()
    joined = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    assert.is_true(joined:find("plain", 1, true) ~= nil, "clear did not restore the tree")
    assert.is_nil(joined:find("user:1", 1, true), "stale search rows after clear")

    browser.close()
    async.load_connections = orig_load
    session_conn.execute = orig_execute
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

  it("scan_keys builds lazy group headers; scan_group loads keys", function()
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
    async.scan_keys(db, url, "browser-e2e")
    -- SCAN is async; poll for loading to finish
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
        -- lazy: headers are created but keys load only on scan_group
        assert.is_nil(ch.children, "group should be lazily unloaded after scan_keys")
      end
    end
    assert.is_true(vim.tbl_contains(names, "user"))
    assert.is_true(vim.tbl_contains(names, "cache"))

    -- expand the user group: scan_group loads its keys
    local user
    for _, ch in ipairs(db.children) do
      if ch.node_type == "group" and ch.name == "user" then user = ch end
    end
    assert.is_truthy(user, "user group missing")
    async.scan_group(user, url, "browser-e2e")
    local gwait = vim.wait(10000, function()
      return user.children ~= nil and #user.children >= 2
    end, 10)
    assert.is_true(gwait, "scan_group did not load user keys")
    local k = user.children[1]
    assert.equals("key", k.node_type)
    assert.equals(0, k.meta.db)
  end)

  it("search renders sub-path matches and search_clear removes them", function()
    if not ok_avail then pending("REDIS_TEST_URL not reachable"); return end
    local tree = require("poste-redis.browser.tree")
    local async = require("poste-redis.browser.async")
    local session_conn = require("poste-redis.session_conn")

    -- seed nested sub-path keys
    local seeded = false
    session_conn.execute(url, {
      "MSET",
      "bench:a:x", "1", "bench:a:b:y", "2", "bench:c:z", "3", "other:1", "4",
    }, {
      on_response = function() seeded = true end,
    }, nil, { db = 0 })
    vim.wait(3000, function() return seeded end, 5)

    local db = tree.make_db_node({ db = 0 }, "search-e2e")
    db.children = {}
    async.search(db, url, "search-e2e", "bench:a")
    local wait_ok = vim.wait(10000, function()
      return not (db._search_results and db._search_results.loading)
    end, 10)
    assert.is_true(wait_ok, "search did not finish in 10s")
    assert.is_truthy(db._search_results, "search results node missing")
    local results = db._search_results
    assert.equals("bench:a", results.name)  -- name = sub-path; the node is never rendered (display root)
    local names = {}
    for _, k in ipairs(results.children or {}) do
      names[#names + 1] = k.name
    end
    assert.is_true(vim.tbl_contains(names, "bench:a:x"), "missing bench:a:x")
    assert.is_true(vim.tbl_contains(names, "bench:a:b:y"), "missing bench:a:b:y")
    assert.is_false(vim.tbl_contains(names, "bench:c:z"), "non-matching key leaked")

    -- clearing drops the results node; the db children were never touched
    async.search_clear(db)
    assert.is_nil(db._search_results)
    for _, ch in ipairs(db.children) do
      assert.is_false(ch.is_search, "search node leaked into db children")
    end
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
