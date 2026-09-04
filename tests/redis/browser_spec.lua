--- browser spec — key browser tree flattening + SCAN grouping (pure logic,
--- no transport: build_children/flatten/fetch_command are tested directly).
local tree = require("poste-redis.browser.tree")
local async = require("poste-redis.browser.async")
local scan = require("poste-redis.browser.scan")
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
    -- no trailing type/size suffix on key rows (type is the icon + color)
    assert.is_nil(lines[3]:match("hash"), "key rows must not carry a type suffix")
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

  it("maps buffer lines to nodes via get_node_at_line (2 header lines offset)", function()
    local conn = tree.make_connection_node({ name = "c", url = "u", dialect = "redis" })
    local db = tree.make_db_node({ db = 1 }, "c")
    local key = tree.make_key_node("k", "c", 1)
    conn.children = { db }
    db.children = { key }
    conn.expanded = true
    db.expanded = true
    local _, node_map = tree.flatten_tree({ conn })
    -- HEADER_LINES = 2: search bar (1) + separator (2), nodes start at line 3
    assert.is_nil(tree.get_node_at_line(node_map, 1))
    assert.is_nil(tree.get_node_at_line(node_map, 2))
    assert.equals(conn, tree.get_node_at_line(node_map, 3))
    assert.equals(db, tree.get_node_at_line(node_map, 4))
    assert.equals(key, tree.get_node_at_line(node_map, 5))
    assert.is_nil(tree.get_node_at_line(node_map, 6))
  end)
end)

describe("poste-redis browser async grouping", function()
  it("builds flat children in flat view", function()
    async.set_view_mode("flat")
    local db = tree.make_db_node({ db = 0 }, "c")
    scan._test.build_children(db, { "a", "b:1", "c" }, "c", 0)
    assert.equals(3, #db.children)
    assert.equals("key", db.children[1].node_type)
    assert.equals("a", db.children[1].name)
  end)

  it("buckets keys by first : segment in tree view", function()
    async.set_view_mode("flatten")
    local db = tree.make_db_node({ db = 0 }, "c")
    scan._test.build_children(db, { "user:1", "user:2", "cache:a", "plain" }, "c", 0)
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
    async.set_view_mode("flatten")
    local db = tree.make_db_node({ db = 0 }, "c")
    scan._test.build_children(db, { "z:a", "a:x", "m:k" }, "c", 0)
    assert.equals(3, #db.children)
    assert.equals("a", db.children[1].name)
    assert.equals("m", db.children[2].name)
    assert.equals("z", db.children[3].name)
  end)

  it("keeps keys without : flat in tree view", function()
    async.set_view_mode("flatten")
    local db = tree.make_db_node({ db = 0 }, "c")
    scan._test.build_children(db, { "nocolon", "has:colon" }, "c", 0)
    local group_count, flat_count = 0, 0
    for _, ch in ipairs(db.children) do
      if ch.node_type == "group" then group_count = group_count + 1
      else flat_count = flat_count + 1 end
    end
    assert.equals(1, group_count)
    assert.equals(1, flat_count)
    assert.equals("nocolon", db.children[1].name)
  end)

  it("builds nested folders per : segment (方案B)", function()
    async.set_view_mode("nested")
    local db = tree.make_db_node({ db = 0 }, "c")
    scan._test.build_children(db, { "a:b:c", "a:b", "a:d", "b:c" }, "c", 0)
    -- DB top: only first-segment folders (a, b), no leaves
    assert.equals(2, #db.children)
    assert.equals("a", db.children[1].name)
    assert.equals("b", db.children[2].name)
    -- expanding `a` (display root is hidden): subfolders first, then leaves
    local a, b = db.children[1], db.children[2]
    assert.equals("group", a.node_type)
    assert.equals("group", b.node_type)
    assert.equals("b", a.children[1].name)      -- subfolder b (prefix a:b)
    assert.equals("a:b", a.children[2].name)    -- leaf a:b
    assert.equals("a:d", a.children[3].name)    -- leaf a:d
    assert.equals("b:c", b.children[1].name)
    -- subfolder b holds a:b:c
    assert.equals("a:b:c", a.children[1].children[1].name)
    assert.equals("key", a.children[1].children[1].node_type)
  end)

  it("set_view_mode normalizes the flat+nested combination", function()
    async.set_view_mode("flat")
    async.nested_view = true  -- invalid combo
    assert.equals("flat", async.view_mode())
    assert.equals("nested", async.set_view_mode("nested"))
    assert.is_true(async.tree_view)
    assert.is_true(async.nested_view)
    assert.equals("flatten", async.set_view_mode("flatten"))
    assert.is_true(async.tree_view)
    assert.is_false(async.nested_view)
  end)

  it("toggle_view_mode alternates flatten <-> nested", function()
    async.set_view_mode("flatten")
    assert.equals("nested", async.toggle_view_mode())
    assert.equals("flatten", async.toggle_view_mode())
    -- from flat goes to nested (the richer layout)
    async.set_view_mode("flat")
    assert.equals("nested", async.toggle_view_mode())
  end)

  it("build_children preserves key type/size through a view rebuild", function()
    -- Regression: toggle_view collected names only, so rebuilding into the
    -- other view made every key render as the default string icon + purple
    -- "other" highlight (meta.type was dropped).
    async.set_view_mode("flatten")
    local db = tree.make_db_node({ db = 0 }, "c")
    local typed = {
      { name = "cache:a", type = "string", size = "4" },
      { name = "user:1", type = "hash", size = "2" },
      { name = "user:2", type = "zset", size = "5" },
      { name = "plain", type = "string" },
    }
    scan._test.build_children(db, typed, "c", 0)
    -- flatten: group user holds its typed keys, cache + plain flat
    local hashes = {}
    for _, ch in ipairs(db.children) do
      if ch.node_type == "group" then
        for _, k in ipairs(ch.children) do hashes[k.name] = k end
      else
        hashes[ch.name] = ch
      end
    end
    assert.equals("hash", hashes["user:1"].meta.type)
    assert.equals("2", hashes["user:1"].meta.size)
    assert.equals("zset", hashes["user:2"].meta.type)
    assert.equals("string", hashes["cache:a"].meta.type)
    assert.equals("string", hashes["plain"].meta.type)
  end)

  it("nested rebuild carries types into the deepest folder leaf", function()
    async.set_view_mode("nested")
    local db = tree.make_db_node({ db = 0 }, "c")
    scan._test.build_children(db, {
      { name = "a:b:c", type = "list", size = "3" },
      { name = "a:b", type = "string" },
      { name = "a:d", type = "set" },
    }, "c", 0)
    local a = db.children[1]
    assert.equals("list", a.children[1].children[1].meta.type)  -- folder b → a:b:c
    assert.equals("3", a.children[1].children[1].meta.size)
    assert.equals("string", a.children[2].meta.type)
    assert.equals("set", a.children[3].meta.type)
  end)

  it("build_children still accepts plain string keys", function()
    async.set_view_mode("flatten")
    local db = tree.make_db_node({ db = 0 }, "c")
    scan._test.build_children(db, { "a", "b:1" }, "c", 0)
    assert.equals("a", db.children[1].name)
    assert.is_nil(db.children[1].meta.type)
    assert.equals("b", db.children[2].name)
    assert.is_nil(db.children[2].children[1].meta.type)
  end)

  it("nested view folds a single-spine group chain into one folder row", function()
    -- JetBrains "compact middle directories": a → b → c are each groups with
    -- exactly one GROUP child, so fold_walk collapses them into one row
    -- mapped to the deepest group (a:b:c). Keys render relative to it.
    async.set_view_mode("nested")
    local db = tree.make_db_node({ db = 0 }, "c")
    local a = tree.make_group_node("a", "c", 0)
    local b = tree.make_group_node("a:b", "c", 0, "b")
    local c = tree.make_group_node("a:b:c", "c", 0, "c")
    a.parent = db
    b.parent = a
    c.parent = b
    a.children = { b }
    b.children = { c }
    c.children = {
      tree.make_key_node("a:b:c:d:x", "c", 0),
      tree.make_key_node("a:b:c:e:x", "c", 0),
    }
    a.expanded = true
    b.expanded = true
    c.expanded = true
    db.children = { a }
    db.expanded = true
    local lines, node_map = tree.flatten_tree({ db })
    -- db row + one folded row for the whole chain + keys relative to it
    assert.equals(4, #lines)
    assert.match("a:b:c", lines[2])
    assert.match("d:x", lines[3])
    assert.match("e:x", lines[4])
    -- the fold row maps to the DEEPEST group, so expand/load/delete keep the
    -- real prefix (a:b:c), never the intermediate a or b
    assert.equals(c, node_map[2])
    assert.equals("key", node_map[3].node_type)
    assert.equals("a:b:c:d:x", node_map[3].meta.key,
      "display shortens, canonical key stays full")
  end)

  it("nested view keeps lone-key folders as expandable groups", function()
    -- A group whose only child is a KEY stays a folder row (expandable, count
    -- shown); the key renders beneath it. fold_walk never absorbs a folder
    -- into its key leaf — node types are never changed.
    async.set_view_mode("nested")
    local db = tree.make_db_node({ db = 0 }, "c")
    local a = tree.make_group_node("a", "c", 0)
    local b = tree.make_group_node("a:b:c", "c", 0)  -- spine under a
    a.parent = db
    b.parent = a
    a.children = { b }
    b.children = {
      tree.make_group_node("a:b:c:d", "c", 0, "d"),
      tree.make_group_node("a:b:c:e", "c", 0, "e"),
    }
    b.children[1].children = { tree.make_key_node("a:b:c:d:x", "c", 0) }
    b.children[2].children = { tree.make_key_node("a:b:c:e:x", "c", 0) }
    a.expanded = true
    b.expanded = true
    db.children = { a }
    db.expanded = true
    local lines = tree.flatten_tree({ db })
    -- db, folded row a:b:c, subfolder d (lone-key, stays folder), subfolder e
    assert.equals(4, #lines)
    assert.match("a:b:c", lines[2])
    -- d and e are folder rows (not absorbed into key leaves), collapsed by default
    assert.match("d", lines[3])
    assert.match("e", lines[4])
  end)

  it("nested view does NOT fold a branching level, and flatten keeps folders", function()
    async.set_view_mode("nested")
    local db = tree.make_db_node({ db = 0 }, "c")
    local a = tree.make_group_node("a", "c", 0)
    local b = tree.make_group_node("a:b", "c", 0, "b")
    local c = tree.make_group_node("a:c", "c", 0, "c")
    a.parent = db
    b.parent = a
    c.parent = a
    a.children = { b, c }
    b.children = { tree.make_key_node("a:b:1", "c", 0) }
    c.children = { tree.make_key_node("a:c:2", "c", 0) }
    a.expanded = true
    -- b and c are lone-key folders: they stay collapsed as folder rows
    -- (expandable, count shown). The fold stops at a's branching level.
    db.children = { a }
    db.expanded = true
    local lines = tree.flatten_tree({ db })
    -- a branches into b and c: the fold stops there, both render as folder rows
    assert.equals(4, #lines)  -- db, a, b (folder), c (folder)
    assert.match("b", lines[3])
    assert.match("c", lines[4])
    -- flatten mode: first-segment folder style, group rows + keys keep names
    async.set_view_mode("flatten")
    local db2 = tree.make_db_node({ db = 0 }, "c")
    local g = tree.make_group_node("user", "c", 0)
    g.children = { tree.make_key_node("user:1", "c", 0) }
    db2.children = { g }
    db2.expanded = true
    g.expanded = true
    local lines2 = tree.flatten_tree({ db2 })
    assert.equals(3, #lines2)  -- db, folder user, key user:1
    assert.match("user%S*", lines2[2])
    assert.match("user:1", lines2[3])
  end)

  it("scan_group builds nested subfolders lazily in nested view", function()
    async.set_view_mode("nested")
    local session_conn = require("poste-redis.session_conn")
    local orig_execute = session_conn.execute
    session_conn.execute = function(conn_url, cmd, cbs)
      -- SCAN MATCH a:* → a:b, a:b:c, a:d → one subfolder + 2 direct keys
      cbs.on_response({ value = { value = { "a:b", "a:b:c", "a:d" }, cursor = "0" } })
      return "dispatched"
    end
    local group = tree.make_group_node("a", "c", 0)
    scan.scan_group(group, "redis://h", "c")
    -- subfolder b created lazily (children nil); leaves a:b / a:d direct
    assert.equals("group", group.children[1].node_type)
    assert.equals("b", group.children[1].name)
    assert.is_nil(group.children[1].children, "subfolder must stay lazy (children nil)")
    assert.equals("a:b", group.children[2].name)
    assert.equals("a:d", group.children[3].name)
    session_conn.execute = orig_execute
  end)

  it("scan_group keeps keys flat in flatten view", function()
    async.set_view_mode("flatten")
    local session_conn = require("poste-redis.session_conn")
    local orig_execute = session_conn.execute
    session_conn.execute = function(conn_url, cmd, cbs)
      cbs.on_response({ value = { value = { "a:b", "a:b:c", "a:d" }, cursor = "0" } })
      return "dispatched"
    end
    local group = tree.make_group_node("a", "c", 0)
    scan.scan_group(group, "redis://h", "c")
    assert.equals("key", group.children[1].node_type)  -- all flat, no subfolders
    assert.equals("a:b", group.children[1].name)
    assert.equals(3, #group.children)
    session_conn.execute = orig_execute
  end)

  it("view_mode default follows config.browser_view_mode", function()
    local config = require("poste-redis.config")
    assert.equals("flatten", config.defaults.browser_view_mode)
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
    -- the icon must NEVER survive into a query: deleting the separator
    -- space (or an already-doubled bar) still parses to the bare query
    assert.equals("que", browser._test.parse_search_line(tree.SEARCH_ICON .. "que"))
    assert.equals("que", browser._test.parse_search_line(prefix .. prefix .. "que"))
  end)

  it("search line holds only the query; the icon + hint are virt text", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "", "", "" })
    local icon = "\239\128\130"

    tree.render_search_line(buf, "")
    assert.equals("", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1],
      "empty state: neither the icon nor the hint may be buffer text")
    assert.is_nil(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]:find(icon, 1, true),
      "the icon must never live in the buffer (it is virt text)")

    tree.render_search_line(buf, "cache")
    assert.equals("cache", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1],
      "committed query stays on the search line")

    -- editing state drops the icon virt text: the caret must never sit on or
    -- before a virt glyph at the same column.
    tree.decorate_search_line(buf, "cache", true)
    local nsid = vim.api.nvim_get_namespaces()["poste_redis_browser_search"]
    local em = nsid and vim.api.nvim_buf_get_extmarks(buf, nsid, 0, -1, {}) or {}
    assert.equals(0, #em, "no icon virt text while editing")
    tree.decorate_search_line(buf, "", false)
    local em2 = nsid and vim.api.nvim_buf_get_extmarks(buf, nsid, 0, -1, {}) or {}
    assert.equals(1, #em2, "idle state restores the icon virt text")

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("separator rule lands under the search bar (2 header lines)", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local sep = browser._test.separator_text()
    assert.truthy(sep:find("^%-+$"), "separator is a dash rule")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { prefix, sep })
    assert.match("^%-+$", vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1])
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("separator tracks a narrowed window and stays on one line", function()
    local browser = require("poste-redis.browser.init")
    local orig_load = async.load_connections
    async.load_connections = function(cb) cb({}) end

    local ok, err = pcall(function() browser.open() end)
    assert.is_true(ok, tostring(err))
    local buf = browser.info().buffer
    local win = browser.info().window
    assert.is_true(win ~= nil and vim.api.nvim_win_is_valid(win))

    -- default split: the dash run spans the window, always narrower than it
    local w = vim.api.nvim_win_get_width(win)
    local sep = vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1]
    assert.match("^%-+$", sep)
    assert.is_true(#sep <= w - 1,
      "separator must fit one line (got " .. #sep .. " dashes in " .. w .. " cols)")

    -- narrow the split; the WinResized refresh must recompute the rule to
    -- the new width instead of leaving a wrapping wide dash run
    pcall(vim.api.nvim_win_set_width, win, 12)
    vim.api.nvim_exec_autocmds("WinResized", {})
    local w2 = vim.api.nvim_win_get_width(win)
    sep = vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1]
    assert.match("^%-+$", sep)
    assert.equals(math.max(w2 - 6, math.min(8, w2 - 1)), #sep,
      "separator length must match the narrowed width")
    assert.is_true(#sep <= w2 - 1,
      "separator must not wrap in a narrow split (got " .. #sep .. " in " .. w2 .. " cols)")

    browser.close()
    async.load_connections = orig_load
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

    async.set_view_mode("flatten")
    local ok, err = pcall(function() browser.open() end)
    assert.is_true(ok, tostring(err))
    local buf = browser.info().buffer
    assert.is_true(vim.wait(2000, function()
      return #vim.api.nvim_buf_get_lines(buf, 0, -1, false) > 3
    end, 5), "db scan did not render")

    -- idle state: the icon is virt text, so line 1 holds no icon/query;
    -- the db scope lives in the winbar, the separator is buffer line 2
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.equals("", lines[1])
    assert.match("^%-+$", lines[2])
    assert.match("db 0",
      vim.api.nvim_get_option_value("winbar", { win = browser.info().window }))
    local joined = table.concat(lines, "\n")
    assert.is_true(joined:find("plain", 1, true) ~= nil, "unfiltered tree missing")

    -- type into the bar: query only, then commit
    browser._test.search_enter()
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "user" })
    browser._test.search_commit()

    -- matched keys REPLACE the tree — no unfiltered rows survive
    lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    joined = table.concat(lines, "\n")
    assert.is_true(joined:find("user:1", 1, true) ~= nil, "match missing")
    assert.is_true(joined:find("user:2", 1, true) ~= nil, "match missing")
    assert.is_nil(joined:find("plain", 1, true), "search appended instead of replacing")
    assert.equals("user", lines[1], "committed query must stay on the bar")

    -- clear restores the unfiltered tree
    browser.search_clear()
    joined = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    assert.is_true(joined:find("plain", 1, true) ~= nil, "clear did not restore the tree")
    assert.is_nil(joined:find("user:1", 1, true), "stale search rows after clear")

    browser.close()
    async.load_connections = orig_load
    session_conn.execute = orig_execute
  end)

  it("search commits a query typed at the line end; the icon stays virt text", function()
    local browser = require("poste-redis.browser.init")
    local session_conn = require("poste-redis.session_conn")

    local orig_load = async.load_connections
    local orig_execute = session_conn.execute
    async.load_connections = function(cb)
      cb({ tree.make_connection_node({
        name = "stub", url = "redis://127.0.0.1:16479/0", dialect = "redis",
      }) })
    end
    session_conn.execute = function(conn_url, cmd, cbs)
      if cbs and cbs.on_response then
        local keys = vim.tbl_contains(cmd, "MATCH") and { "user:1", "user:2" }
          or { "user:1", "user:2", "plain" }
        cbs.on_response({ value = { value = keys, cursor = "0" } })
      end
      return "dispatched"
    end

    async.set_view_mode("flatten")
    local ok, err = pcall(function() browser.open() end)
    assert.is_true(ok, tostring(err))
    local buf = browser.info().buffer
    browser._test.select_db(0)  -- clear state left by earlier window tests
    assert.is_true(vim.wait(2000, function()
      return #vim.api.nvim_buf_get_lines(buf, 0, -1, false) > 3
    end, 5), "db scan did not render")

    -- enter the search bar: the caret must land ON THE TRUE END of the
    -- search line — the bar holds ONLY the query, so real insert typing
    -- appends cleanly. The icon is idle-only virt text: it is dropped while
    -- editing so the caret can never sit on or before it.
    browser._test.search_enter()
    local line1 = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
    assert.equals("", line1, "search bar must start with no icon in the buffer")
    local nsid = vim.api.nvim_get_namespaces()["poste_redis_browser_search"]
    local em = nsid and vim.api.nvim_buf_get_extmarks(buf, nsid, 0, -1, {}) or {}
    assert.equals(0, #em,
      "editing state must drop the icon virt text (caret sits right of nothing)")
    local cursor = vim.api.nvim_win_get_cursor(0)
    assert.equals(1, cursor[1], "search_enter must leave the caret on the search line")
    assert.equals(0, cursor[2],
      "caret must sit on the true EOL (col 0 on an empty bar), not inside any prefix")

    -- type as the fixed caret does: append at the true end of the line
    vim.api.nvim_buf_set_text(buf, 0, #line1, 0, #line1, { "que" })
    assert.equals("que", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1],
      "typed query must be the only buffer text")

    browser._test.search_commit()
    local committed = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
    assert.equals("que", committed,
      "committed bar must be the bare query, no icon in the buffer (" .. committed .. ")")
    assert.equals("que", browser._test.parse_search_line(committed),
      "the icon must never leak into the committed query")
    local joined = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    assert.is_true(joined:find("user:1", 1, true) ~= nil, "search with 'que' missing matches")
    assert.is_nil(joined:find("plain", 1, true), "unfiltered rows survived the search")

    browser.close()
    async.load_connections = orig_load
    session_conn.execute = orig_execute
  end)

  it("<leader>/ from a tree row jumps the caret to the search bar, not the row", function()
    local browser = require("poste-redis.browser.init")
    local session_conn = require("poste-redis.session_conn")

    local orig_load = async.load_connections
    local orig_execute = session_conn.execute
    async.load_connections = function(cb)
      cb({ tree.make_connection_node({
        name = "stub", url = "redis://127.0.0.1:16479/0", dialect = "redis",
      }) })
    end
    session_conn.execute = function(conn_url, cmd, cbs)
      if cbs and cbs.on_response then
        local keys = vim.tbl_contains(cmd, "MATCH") and { "user:1", "user:2" }
          or { "user:1", "user:2", "plain" }
        cbs.on_response({ value = { value = keys, cursor = "0" } })
      end
      return "dispatched"
    end

    async.set_view_mode("flatten")
    local ok, err = pcall(function() browser.open() end)
    assert.is_true(ok, tostring(err))
    local buf = browser.info().buffer
    browser._test.select_db(0)
    assert.is_true(vim.wait(2000, function()
      return #vim.api.nvim_buf_get_lines(buf, 0, -1, false) > 3
    end, 5), "db scan did not render")

    -- park the caret on a tree row (below the 3 header lines), then search
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    local row_line = vim.api.nvim_buf_get_lines(buf, 3, 4, false)[1]
    assert.truthy(row_line and row_line ~= "", "row under the caret must be a tree row")

    browser._test.search_enter()
    local cursor = vim.api.nvim_win_get_cursor(0)
    assert.equals(1, cursor[1],
      "search_enter from a tree row must move the caret to the search bar, not insert on the row")
    assert.equals(0, cursor[2], "caret sits at the true EOL of the (empty) search bar")

    browser.close()
    async.load_connections = orig_load
    session_conn.execute = orig_execute
  end)

  it("h after l keeps the cursor on the collapsed group line", function()
    local browser = require("poste-redis.browser.init")
    local session_conn = require("poste-redis.session_conn")

    local orig_load = async.load_connections
    local orig_execute = session_conn.execute
    async.load_connections = function(cb)
      cb({ tree.make_connection_node({
        name = "stub", url = "redis://127.0.0.1:16479/0", dialect = "redis",
      }) })
    end
    -- db scan (no MATCH) yields group seeds; group scan (MATCH queue:*) its keys
    session_conn.execute = function(conn_url, cmd, cbs)
      if cbs and cbs.on_response then
        local keys
        if vim.tbl_contains(cmd, "MATCH") then
          keys = { "queue:item:1", "queue:item:2" }
        else
          keys = { "big-value", "board", "plain", "queue:item:1" }
        end
        cbs.on_response({ value = { value = keys, cursor = "0" } })
      end
      return "dispatched"
    end

    async.set_view_mode("flatten")  -- earlier blocks may leave flat view
    local ok, err = pcall(function() browser.open() end)
    assert.is_true(ok, tostring(err))
    local buf = browser.info().buffer
    -- earlier window tests leave the browser scoped to their stub db; a
    -- fresh select_db re-scans the current connection with THIS stub
    browser._test.select_db(0)
    assert.is_true(vim.wait(2000, function()
      return #vim.api.nvim_buf_get_lines(buf, 0, -1, false) > 3
    end, 5), "db scan did not render")

    -- the queue group sits below the flat keys (big-value/board/plain)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local group_line
    for n, line in ipairs(lines) do
      if line:find("queue", 1, true) and line:find("\239\132\133", 1, true) then
        group_line = n
        break
      end
    end
    assert.is_truthy(group_line, "collapsed queue group row not found")
    vim.api.nvim_win_set_cursor(0, { group_line, 0 })

    -- expand (lazy group scan) then collapse: cursor must stay on queue
    browser._test.expand_or_child()
    assert.is_true(vim.wait(2000, function()
      return #vim.api.nvim_buf_get_lines(buf, 0, -1, false) > #lines
    end, 5), "group did not expand")
    browser._test.collapse_or_parent()

    local after = vim.api.nvim_win_get_cursor(0)[1]
    assert.equals(group_line, after,
      "collapse jumped the cursor from line " .. group_line .. " to " .. after)
    assert.equals(#lines, #vim.api.nvim_buf_get_lines(buf, 0, -1, false),
      "collapse should restore the collapsed row count")

    browser.close()
    async.load_connections = orig_load
    session_conn.execute = orig_execute
  end)

  it("toggle_view keeps lazy (unexpanded) groups — re-scans instead of rebuilding", function()
    local browser = require("poste-redis.browser.init")
    local session_conn = require("poste-redis.session_conn")

    local orig_load = async.load_connections
    local orig_execute = session_conn.execute
    async.load_connections = function(cb)
      cb({ tree.make_connection_node({
        name = "stub", url = "redis://127.0.0.1:16479/0", dialect = "redis",
      }) })
    end
    -- every db-level scan returns the same key set; groups stay LAZY
    -- (children = nil until expanded)
    session_conn.execute = function(conn_url, cmd, cbs)
      if cbs and cbs.on_response then
        cbs.on_response({ value = { value = { "user:1", "cache:a", "plain" }, cursor = "0" } })
      end
      return "dispatched"
    end

    async.set_view_mode("flatten")
    local ok, err = pcall(function() browser.open() end)
    assert.is_true(ok, tostring(err))
    local buf = browser.info().buffer
    browser._test.select_db(0)
    assert.is_true(vim.wait(2000, function()
      return #vim.api.nvim_buf_get_lines(buf, 0, -1, false) > 3
    end, 5), "db scan did not render")

    local function rows()
      local out = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      return {
        user = out:find("user", 1, true) ~= nil,
        cache = out:find("cache", 1, true) ~= nil,
        plain = out:find("plain", 1, true) ~= nil,
      }
    end
    assert.is_true(rows().user and rows().cache and rows().plain, "seed rows missing")

    -- toggle flatten -> nested -> flatten. The groups were never expanded, so
    -- a collect-and-rebuild would drop them; re-scan must bring them back.
    browser.toggle_view("nested")
    assert.is_true(vim.wait(2000, function()
      local r = rows()
      return r.user and r.cache
    end, 5), "nested toggle lost rows")
    browser.toggle_view("flatten")
    assert.is_true(vim.wait(2000, function()
      local r = rows()
      return r.user and r.cache and r.plain
    end, 5), "flatten toggle lost rows")

    browser.close()
    async.load_connections = orig_load
    session_conn.execute = orig_execute
  end)
end)

describe("poste-redis browser auto-width", function()
  local config = require("poste-redis.config")

  it("render_tree records the longest visible data row in display cells", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local db = tree.make_db_node({ db = 0 }, "c")
    db.children = {
      tree.make_key_node("cache:this-is-a-long-key-name", "c", 0),
      tree.make_key_node("x", "c", 0),
    }
    db.expanded = true
    tree.display_root = db
    tree.header_lines = { "", "----------------" }
    tree.render_tree(buf, {}, { db })
    tree.display_root = nil
    local icons = require("poste-redis.icons")
    local expected = vim.fn.strdisplaywidth(
      "  " .. icons.KEY_ICON.string .. " cache:this-is-a-long-key-name")
    assert.equals(expected, tree.last_content_width)
    -- short trees do not dip below a sane floor (min width applies in the
    -- browser; render_tree itself only measures — no clamping here)
    local db2 = tree.make_db_node({ db = 0 }, "c")
    db2.children = { tree.make_key_node("k", "c", 0) }
    db2.expanded = true
    tree.display_root = db2
    tree.render_tree(buf, {}, { db2 })
    tree.display_root = nil
    assert.equals(vim.fn.strdisplaywidth("  " .. icons.KEY_ICON.string .. " k"),
      tree.last_content_width)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("grows the split past the default 30 to fit a long expanded key", function()
    local browser = require("poste-redis.browser.init")
    local session_conn = require("poste-redis.session_conn")

    local orig_load = async.load_connections
    local orig_execute = session_conn.execute
    async.load_connections = function(cb)
      cb({ tree.make_connection_node({
        name = "stub", url = "redis://127.0.0.1:16479/0", dialect = "redis",
      }) })
    end
    session_conn.execute = function(conn_url, cmd, cbs)
      if cbs and cbs.on_response then
        local keys = vim.tbl_contains(cmd, "MATCH")
          and { "xx" }
          or { "this-is-a-very-long-key-that-forces-a-wider-split", "small" }
        cbs.on_response({ value = { value = keys, cursor = "0" } })
      end
      return "dispatched"
    end

    async.set_view_mode("flat")
    local ok, err = pcall(function() browser.open() end)
    assert.is_true(ok, tostring(err))
    local win = browser.info().window
    browser._test.select_db(0)
    -- the long key renders unwrapped ⇒ the split must widen past the 30-col
    -- default (flat view puts the key at depth 0)
    local cap = math.floor(vim.o.columns * (config.config.browser_width_max_ratio or 0.7))
    assert.is_true(vim.wait(3000, function()
      return vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_width(win) > 30
    end, 10), "auto-width did not grow the window past 30")
    local w = vim.api.nvim_win_get_width(win)
    assert.is_true(w <= cap, "auto-width must respect the editor cap (got " .. w .. " > " .. cap .. ")")

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

    async.set_view_mode("flatten")
    local db = tree.make_db_node({ db = 0 }, "browser-e2e")
    scan.scan_keys(db, url, "browser-e2e")
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
    scan.scan_group(user, url, "browser-e2e")
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

  it("nested view builds a:b:c → a/b folder tree through live redis", function()
    if not ok_avail then pending("REDIS_TEST_URL not reachable"); return end
    local tree = require("poste-redis.browser.tree")
    local async = require("poste-redis.browser.async")
    local session_conn = require("poste-redis.session_conn")
    async.set_view_mode("nested")

    -- self-seed fixture keys under unique top prefixes (the suite shares the
    -- db with the 100k-key bench, so a full scan could hit render caps).
    -- Scan each root prefix separately to mirror the user's a:b, a:b:c, a:d / b:c shape.
    local seeded = false
    session_conn.execute(url, {
      "MSET", "xa1b:b:c", "abc", "xa1b:b", "ab", "xa1b:d", "ad", "zb2:c", "bc",
    }, {
      on_response = function() seeded = true end,
    }, nil, { db = 0 })
    vim.wait(3000, function() return seeded end, 5)

    local db = tree.make_db_node({ db = 0 }, "nested-e2e")
    scan.scan_keys(db, url, "nested-e2e", "xa1b:*")
    assert.is_true(vim.wait(10000, function() return db.children and #db.children >= 1 end, 10),
      "scan xa1b:* produced no folder")

    -- top folder xa1b (first : segment)
    local top
    for _, ch in ipairs(db.children) do
      if ch.node_type == "group" and ch.name == "xa1b" then top = ch end
    end
    assert.is_truthy(top, "folder xa1b missing")

    -- expand xa1b → subfolder b (prefix xa1b:b) + direct keys xa1b:b, xa1b:d
    scan.scan_group(top, url, "nested-e2e")
    assert.is_true(vim.wait(10000, function() return not top.loading and top.children and #top.children >= 2 end, 10),
      "folder xa1b did not expand")
    local direct = {}
    local sub_b
    for _, c in ipairs(top.children) do
      if c.node_type == "key" then direct[#direct + 1] = c.name end
      if c.node_type == "group" and c.name == "b" then sub_b = c end
    end
    assert.is_true(vim.tbl_contains(direct, "xa1b:b"), "xa1b:b must be a direct key under xa1b")
    assert.is_true(vim.tbl_contains(direct, "xa1b:d"), "xa1b:d must be a direct key under xa1b")
    assert.is_truthy(sub_b, "subfolder b under xa1b missing")
    assert.is_nil(sub_b.children, "subfolder must stay lazy before expand")

    -- expand xa1b:b → key xa1b:b:c
    scan.scan_group(sub_b, url, "nested-e2e")
    assert.is_true(vim.wait(10000, function() return not sub_b.loading and sub_b.children and #sub_b.children >= 1 end, 10),
      "subfolder xa1b:b did not expand")
    assert.equals("xa1b:b:c", sub_b.children[1].name)

    -- second top prefix zb2 → folder zb2 with key zb2:c
    local db2 = tree.make_db_node({ db = 0 }, "nested-e2e")
    scan.scan_keys(db2, url, "nested-e2e", "zb2:*")
    assert.is_true(vim.wait(10000, function() return db2.children and #db2.children >= 1 end, 10),
      "scan zb2:* produced no folder")
    local top2 = db2.children[1]
    assert.equals("zb2", top2.name)
    scan.scan_group(top2, url, "nested-e2e")
    assert.is_true(vim.wait(10000, function() return not top2.loading and top2.children and #top2.children >= 1 end, 10),
      "folder zb2 did not expand")
    assert.equals("zb2:c", top2.children[1].name)
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

describe("poste-redis browser expand regressions", function()
  local session_conn = require("poste-redis.session_conn")

  it("shows a status line while the hidden display root is scanning", function()
    local db = tree.make_db_node({ db = 0 }, "c")
    db.loading = true
    db.expanded = true
    db.children = {}
    tree.display_root = db
    local lines, node_map = tree.flatten_tree({ db })
    tree.display_root = nil
    -- the db node has no row of its own; without this a slow/failed scan
    -- renders as a silently blank tree
    assert.equals(1, #lines)
    assert.match("scanning", lines[1])
    assert.equals(db, node_map[1])
    assert.equals(1, db._desc_lines)
  end)

  it("shows the hidden display root's scan error", function()
    local db = tree.make_db_node({ db = 0 }, "c")
    db.error = "connection refused"
    db.expanded = true
    db.children = {}
    tree.display_root = db
    local lines = tree.flatten_tree({ db })
    tree.display_root = nil
    assert.equals(1, #lines)
    assert.match("scan failed: connection refused", lines[1])
  end)

  it("appends an error suffix to a failed group node", function()
    local g = tree.make_group_node("user", "c", 0)
    g.error = "ERR db index out of range"
    local lines = tree.flatten_tree({ g })
    assert.match("%(error: ERR db index out of range%)", lines[1])
  end)

  it("append_children keeps ancestors' _desc_lines in sync", function()
    -- two scans can stream at once (db groups + a group's keys): the db
    -- append computes its insert offset from the db node's _desc_lines, so
    -- a stale count splices lines into the middle of the group's keys
    async.set_view_mode("flatten")  -- single-key groups fold in nested view
    local buf = vim.api.nvim_create_buf(false, true)
    local db = tree.make_db_node({ db = 0 }, "c")
    local grp = tree.make_group_node("user", "c", 0)
    grp.parent = db
    db.children = { grp }
    db.expanded = true
    grp.expanded = true
    tree.display_root = db
    tree.header_lines = { "", "", "" }
    local line_to_node = tree.render_tree(buf, {}, { db })
    assert.equals(1, #line_to_node)
    local keys = {
      tree.make_key_node("user:1", "c", 0),
      tree.make_key_node("user:2", "c", 0),
    }
    for _, k in ipairs(keys) do k.parent = grp end
    assert.is_true(tree.append_children(buf, line_to_node, grp, keys))
    assert.equals(2, grp._desc_lines)
    assert.equals(3, db._desc_lines)  -- 1 group row + 2 appended keys
    assert.equals(6, vim.api.nvim_buf_line_count(buf))  -- 3 headers + 3 rows
    tree.display_root = nil
  end)

  it("fetch_types caps TYPE requests (no one-request-per-key session flood)", function()
    local orig_execute = session_conn.execute
    local dispatched = 0
    local inflight = {}
    session_conn.execute = function(conn_url, cmd, cbs, bufnr, opts)
      dispatched = dispatched + 1
      inflight[#inflight + 1] = cbs
      return "dispatched"
    end
    local nodes = {}
    for i = 1, 1200 do nodes[i] = tree.make_key_node("k" .. i, "c", 0) end
    async.fetch_types(nodes, "redis://h", 0)
    -- windowed: only the first window is on the wire at once
    assert.equals(64, #inflight)
    -- drain: each response refills the window until the cap is hit
    while #inflight > 0 do
      local cbs = table.remove(inflight, 1)
      cbs.on_response({ value = { value = "string" } })
    end
    assert.equals(500, dispatched)  -- config.type_fetch_limit, NOT #nodes
    assert.equals("string", nodes[1].meta.type)
    assert.equals("string", nodes[500].meta.type)
    assert.is_nil(nodes[501].meta.type)  -- beyond the cap: never sent
    session_conn.execute = orig_execute
  end)

  it("fetch_types drains on errors and skips already-typed nodes", function()
    local orig_execute = session_conn.execute
    local inflight = {}
    session_conn.execute = function(conn_url, cmd, cbs)
      inflight[#inflight + 1] = cbs
      return "dispatched"
    end
    local nodes = {
      tree.make_key_node("typed", "c", 0, { type = "hash" }),
      tree.make_key_node("a", "c", 0),
      tree.make_key_node("b", "c", 0),
    }
    async.fetch_types(nodes, "redis://h", 0)
    assert.equals(2, #inflight)  -- the already-typed node is skipped
    while #inflight > 0 do
      local cbs = table.remove(inflight, 1)
      cbs.on_error("boom")
    end
    assert.equals("hash", nodes[1].meta.type)
    assert.is_nil(nodes[2].meta.type)
    session_conn.execute = orig_execute
  end)

  it("fetch_types aborts refills when the guarding node's epoch advances", function()
    local orig_execute = session_conn.execute
    local dispatched = 0
    local inflight = {}
    session_conn.execute = function(conn_url, cmd, cbs)
      dispatched = dispatched + 1
      inflight[#inflight + 1] = cbs
      return "dispatched"
    end
    local db = tree.make_db_node({ db = 0 }, "c")
    db.epoch = 1
    local nodes = {}
    for i = 1, 300 do nodes[i] = tree.make_key_node("k" .. i, "c", 0) end
    async.fetch_types(nodes, "redis://h", 0, db)
    assert.equals(64, #inflight)  -- first window on the wire
    -- a refresh bumps the node epoch → the batch must stop refilling
    db.epoch = 2
    while #inflight > 0 do
      local cbs = table.remove(inflight, 1)
      cbs.on_response({ value = { value = "string" } })
    end
    assert.equals(64, dispatched)  -- not 300: no refill after the guard tripped
    -- the superseded batch applies nothing: the fresh scan owns the new tree
    assert.is_nil(nodes[1].meta.type)
    assert.is_nil(nodes[300].meta.type)
    session_conn.execute = orig_execute
  end)
end)

describe("poste-redis browser render cap", function()
  local config = require("poste-redis.config")

  it("flatten stops at the budget and reports skipped rows", function()
    local db = tree.make_db_node({ db = 0 }, "c")
    db.children = {}
    for i = 1, 50 do db.children[i] = tree.make_key_node("k" .. i, "c", 0) end
    db.expanded = true
    tree.display_root = db
    local lines, _, _, skipped = tree.flatten_tree({ db }, 0, nil, 10)
    assert.equals(10, #lines)
    assert.equals(40, skipped)
    -- no budget: everything renders, nothing skipped
    local all_lines, _, _, all_skipped = tree.flatten_tree({ db }, 0, nil, nil)
    tree.display_root = nil
    assert.equals(50, #all_lines)
    assert.equals(0, all_skipped)
  end)

  it("render_tree appends a truncation notice row", function()
    local orig = config.config.render_max_lines
    config.config.render_max_lines = 10
    local buf = vim.api.nvim_create_buf(false, true)
    local db = tree.make_db_node({ db = 0 }, "c")
    db.children = {}
    for i = 1, 50 do db.children[i] = tree.make_key_node("k" .. i, "c", 0) end
    db.expanded = true
    tree.display_root = db
    tree.header_lines = { "", "", "" }
    local l2n = tree.render_tree(buf, {}, { db })
    tree.display_root = nil
    -- node map: capped rows + notice row (header lines are not node rows)
    assert.equals(10 + 1, #l2n)
    assert.equals("notice", l2n[#l2n].node_type)
    -- buffer: 3 header rows + capped rows + notice row
    assert.equals(3 + 10 + 1, vim.api.nvim_buf_line_count(buf))
    local last = vim.api.nvim_buf_get_lines(buf, -2, -1, false)[1]
    assert.match("40 more not rendered", last)
    assert.equals(40, tree.last_truncated)
    config.config.render_max_lines = orig
    tree.last_truncated = 0
  end)

  it("append_children refuses to append past the cap", function()
    local orig = config.config.render_max_lines
    config.config.render_max_lines = 10
    local buf = vim.api.nvim_create_buf(false, true)
    local db = tree.make_db_node({ db = 0 }, "c")
    local grp = tree.make_group_node("user", "c", 0)
    grp.parent = db
    db.children = { grp }
    db.expanded = true
    grp.expanded = true
    tree.display_root = db
    tree.header_lines = { "", "", "" }
    local l2n = tree.render_tree(buf, {}, { db })
    -- tree holds 1 row; cap 10: appending 10 keys would exceed it
    local keys = {}
    for i = 1, 10 do keys[i] = tree.make_key_node("user:" .. i, "c", 0) end
    for _, k in ipairs(keys) do k.parent = grp end
    assert.is_false(tree.append_children(buf, l2n, grp, keys))
    config.config.render_max_lines = orig
    tree.last_truncated = 0
  end)
end)

describe("poste-redis browser per-node render cap", function()
  it("caps a huge group's keys but keeps sibling groups reachable", function()
    local db = tree.make_db_node({ db = 0 }, "c")
    local big = tree.make_group_node("bench", "c", 0)
    big.children = {}
    for i = 1, 1000 do big.children[i] = tree.make_key_node("bench:" .. i, "c", 0) end
    big.expanded = true
    local small = tree.make_group_node("user", "c", 0)
    db.children = { big, small }
    db.expanded = true
    tree.display_root = db
    local lines, node_map, _, skipped = tree.flatten_tree({ db })
    tree.display_root = nil
    -- bench row + 500 capped keys + inline notice + user row
    assert.equals(1 + 500 + 1 + 1, #lines)
    assert.match("bench", lines[1])
    assert.match("500 more", lines[502])
    assert.equals("notice", node_map[502].node_type)
    assert.match("user", lines[503])
    assert.equals(500, skipped)  -- 500 bench keys hidden by the per-node cap
  end)
end)


describe("poste-redis browser gray text (hint / separator)", function()
  it("renders key nodes WITHOUT a trailing type suffix", function()
    local db = tree.make_db_node({ db = 0 }, "c")
    db.children = { tree.make_key_node("user:1", "c", 0, { type = "hash", size = "2" }) }
    db.expanded = true
    local lines, node_map = tree.flatten_tree({ db })
    local node = node_map[2]  -- [1] is the db wrapper, [2] the key node
    -- the type is conveyed by the icon glyph + color only — no text tail
    assert.is_nil(node._suffix_s)
    assert.is_nil(node._suffix_e)
    assert.is_nil(lines[2]:match("hash"), "type text must not render after the key")
    assert.is_nil(lines[2]:match("string"), "type text must not render after the key")
    assert.match("user:1$", lines[2])
  end)

  it("decorates the separator line gray via @comment", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "", "----------" })
    tree.decorate_separator(buf, "----------")
    local ns = vim.api.nvim_create_namespace("poste_redis_browser_header")
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    assert.equals(1, #marks)
    assert.equals("PosteRedisBrowserSep", marks[1][4].hl_group)
    assert.equals(1, marks[1][2])  -- line 2 (0-based 1)
  end)
end)


describe("poste-redis browser node info", function()
  it("format_bytes humanizes sizes", function()
    local info = require("poste-redis.browser.info")
    assert.equals("512 B", info.format_bytes(512))
    assert.equals("2.0 KB", info.format_bytes(2048))
    assert.equals("1.5 MB", info.format_bytes(1536 * 1024))
    assert.equals("?", info.format_bytes(nil))
  end)

  it("key info gathers type/memory/ttl through the session", function()
    local session_conn = require("poste-redis.session_conn")
    local orig = session_conn.execute
    local replies = {
      TYPE = "hash", ENCODING = "listpack",
    }
    session_conn.execute = function(url, cmd, cbs, bufnr, opts)
      local head = cmd[1]
      local v
      if head == "TYPE" then v = { type = "string", value = replies.TYPE }
      elseif head == "OBJECT" then v = { type = "string", value = replies.ENCODING }
      elseif head == "MEMORY" then v = { type = "integer", value = 2048 }
      elseif head == "TTL" then v = { type = "integer", value = -1 }
      end
      cbs.on_response({ value = v })
      return "dispatched"
    end
    local lines
    local info = require("poste-redis.browser.info")
    -- key_info is private; drive through show() with a key node + capture
    local doc = require("poste-redis.doc")
    local orig_preview = doc.open_doc_preview
    doc.open_doc_preview = function(l) lines = l; return 1, 2, false end
    info.show(tree.make_key_node("user:1", "c", 0), { url = "redis://x" })
    doc.open_doc_preview = orig_preview
    session_conn.execute = orig
    assert.is_truthy(lines)
    local text = table.concat(lines, "\n")
    assert.match("hash", text)
    assert.match("listpack", text)
    assert.match("2.0 KB", text)
    assert.match("persistent", text)
  end)
end)


describe("poste-redis browser delete node + multi-select", function()
  local actions = require("poste-redis.browser.actions")
  local session_conn = require("poste-redis.session_conn")
  local browser = require("poste-redis.browser.init")

  after_each(function()
    actions._test.set_confirm(nil)
    session_conn.execute = nil
  end)

  it("d on a group scans all keys, confirms y and removes the node", function()
    local db = tree.make_db_node({ db = 0 }, "c")
    db.meta.url = "redis://127.0.0.1:16479/0"
    local group = tree.make_group_node("queue", "c", 0)
    group.meta.url = "redis://127.0.0.1:16479/0"
    group.parent = db
    db.children = { group }
    -- SCAN returns two pages of keys, then DEL per key
    local pages = { { "queue:1", "queue:2" }, { "queue:3" } }
    local page_i = 0
    local deleted = {}
    session_conn.execute = function(url, cmd, cbs)
      if cmd[1] == "SCAN" then
        page_i = page_i + 1
        local page = pages[page_i] or {}
        local cursor = page_i >= #pages and "0" or tostring(page_i)
        cbs.on_response({ value = { value = page, cursor = cursor } })
      elseif cmd[1] == "DEL" then
        deleted[#deleted + 1] = cmd[2]
        cbs.on_response({ value = { type = "integer", value = 1 } })
      end
      return "dispatched"
    end
    actions._test.set_confirm(function() return true end)  -- y
    local rendered = false
    async.render_hook = function() rendered = true end
    actions.delete_node(group, { db_node = db, render = function() rendered = true end })
    async.render_hook = nil
    assert.same({ "queue:1", "queue:2", "queue:3" }, deleted)
    -- the node is dropped from the parent (reload restarts the db scan)
    for _, ch in ipairs(db.children) do
      assert.is_false(ch == group, "deleted group must not survive in the parent")
    end
    assert.is_true(rendered)
  end)

  it("confirm n cancels the node deletion", function()
    local db = tree.make_db_node({ db = 0 }, "c")
    db.meta.url = "redis://127.0.0.1:16479/0"
    local group = tree.make_group_node("queue", "c", 0)
    group.meta.url = "redis://127.0.0.1:16479/0"
    group.parent = db
    db.children = { group }
    session_conn.execute = function(url, cmd, cbs)
      if cmd[1] == "SCAN" then
        cbs.on_response({ value = { value = { "queue:1" }, cursor = "0" } })
      elseif cmd[1] == "DEL" then
        assert.fail("DEL must not run after cancel")
      end
      return "dispatched"
    end
    actions._test.set_confirm(function() return false end)  -- n / esc
    actions.delete_node(group, { db_node = db, render = function() end })
    assert.equals(1, #db.children)
  end)

  it("multi-select renders a ✓ marker and toggles per node", function()
    local db = tree.make_db_node({ db = 0 }, "c")
    local g1 = tree.make_group_node("a", "c", 0)
    local g2 = tree.make_group_node("b", "c", 0)
    db.children = { g1, g2 }
    db.expanded = true
    tree.display_root = db
    local sel = { selected = { [g1] = true } }
    local lines, node_map = tree.flatten_tree({ db }, 0, sel)
    tree.display_root = nil
    assert.match("✓", lines[1])
    assert.is_nil(lines[2]:match("✓"))
    assert.equals(g1, node_map[1])
  end)

  it("<Tab> toggles selection; D batch-deletes all selected nodes", function()
    -- open the browser with stubs and seed groups via select_db
    local orig_load = async.load_connections
    async.load_connections = function(cb)
      cb({ tree.make_connection_node({ name = "stub", url = "redis://127.0.0.1:16479/0", dialect = "redis" }) })
    end
    -- group nodes carry no meta.url (scan-built); make conn resolution work
    local connections = require("poste-redis.connections")
    local orig_resolve = connections.resolve_redis_url
    connections.resolve_redis_url = function() return "redis://127.0.0.1:16479/0" end
    local orig_execute = session_conn.execute
    local deleted = {}
    session_conn.execute = function(url, cmd, cbs)
      if cmd[1] == "SCAN" then
        local match = cmd[6] or ""
        local keys
        if match:find("user:") then keys = { "user:1", "user:2" }
        elseif match:find("cache:") then keys = { "cache:a" }
        else keys = { "user:1", "cache:a", "plain" } end
        cbs.on_response({ value = { value = keys, cursor = "0" } })
      elseif cmd[1] == "DEL" then
        deleted[#deleted + 1] = cmd[2]
        cbs.on_response({ value = { type = "integer", value = 1 } })
      end
      return "dispatched"
    end
    async.set_view_mode("flatten")  -- db scan stubs yield user:/cache: groups
    browser.open({ source_buf = vim.api.nvim_get_current_buf() })
    browser._test.select_db(0)
    vim.wait(2000, function()
      local b = browser.info().buffer
      if b == nil then return false end
      local ls = vim.api.nvim_buf_get_lines(b, 0, -1, false)
      for _, l in ipairs(ls) do
        if l:find("user", 1, true) then return true end
      end
      return false
    end, 5)
    -- toggle two groups into the selection
    local b = browser.info().buffer
    local ls = vim.api.nvim_buf_get_lines(b, 0, -1, false)
    local targets = {}
    for n, l in ipairs(ls) do
      if l:find("user", 1, true) or l:find("cache", 1, true) then targets[#targets + 1] = n end
    end
    local win = vim.fn.bufwinid(b)
    vim.api.nvim_set_current_win(win)
    actions._test.set_confirm(function() return true end)
    for _, n in ipairs(targets) do
      vim.api.nvim_win_set_cursor(win, { n, 0 })
      browser._test.toggle_multi_select()
    end
    local sel = browser._test.multi_select_state()
    assert.is_true(sel.active)
    assert.equals(2, vim.tbl_count(sel.selected))
    -- D batch-deletes (cursor sits on a selected row)
    vim.api.nvim_win_set_cursor(win, { targets[1], 0 })
    vim.api.nvim_feedkeys("D", "mx", false)
    vim.wait(2000, function() return #deleted >= 3 end, 10)
    assert.is_true(#deleted >= 3, "expected batch DELs, got " .. #deleted)
    assert.is_true(vim.tbl_contains(deleted, "user:1"))
    assert.is_true(vim.tbl_contains(deleted, "cache:a"))
    assert.is_false(browser._test.multi_select_state().active)
    async.load_connections = orig_load
    connections.resolve_redis_url = orig_resolve
    session_conn.execute = orig_execute
  end)
end)

describe("poste-redis browser child counts", function()
  it("stamps lazy group headers with their scanned key counts", function()
    async.set_view_mode("flatten")
    local db = tree.make_db_node({ db = 0 }, "c")
    db.children = {}  -- scan_keys initializes children before scanning
    -- page 1: two cache keys + one plain; page 2 adds a third cache key
    scan._test.build_group_headers(db, { "cache:a", "cache:b", "plain" }, "c", 0, 1)
    scan._test.build_group_headers(db, { "cache:a", "cache:b", "plain", "cache:c" }, "c", 0, 4)
    assert.equals(2, #db.children)  -- one group header + one flat key
    assert.equals("group", db.children[1].node_type)
    assert.equals("cache", db.children[1].name)
    assert.equals(3, db.children[1]._child_count)
  end)

  it("stamps nested subfolder headers with their scanned key counts", function()
    async.set_view_mode("nested")
    local group = tree.make_group_node("a", "c", 0)
    -- build_group_nested returns the new nodes; scan_group splices them in
    local new_nodes = scan._test.build_group_nested(
      group, { "a:b:x", "a:b:y", "a:c", "a:d" }, "c", 0, 1)
    assert.equals(3, #new_nodes)  -- lazy subfolder b + 2 leaves
    assert.equals("group", new_nodes[1].node_type)
    assert.equals("b", new_nodes[1].name)
    assert.equals(2, new_nodes[1]._child_count)
  end)

  it("renders gray child counts as eol virt text on group rows only", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local db = tree.make_db_node({ db = 0 }, "c")
    local lazy_group = tree.make_group_node("bench", "c", 0)
    lazy_group._child_count = 10
    local loaded = tree.make_group_node("cache", "c", 0)
    loaded.children = {
      tree.make_key_node("cache:1", "c", 0),
      tree.make_key_node("cache:2", "c", 0),
    }
    local failed = tree.make_group_node("err", "c", 0)
    failed._child_count = 7
    failed.error = "boom"
    db.children = { lazy_group, loaded, failed, tree.make_key_node("plain", "c", 0) }
    db.expanded = true
    tree.display_root = db
    tree.header_lines = { "", "----------------" }
    tree.render_tree(buf, {}, { db })
    tree.display_root = nil

    local ns = vim.api.nvim_create_namespace("poste_redis_browser")
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    local counts = {}
    for _, m in ipairs(marks) do
      if m[4].virt_text then counts[#counts + 1] = m[4].virt_text[1][1] end
    end
    -- lazy stamp + loaded #children (kept ≥2 so it isn't folded into its lone
    -- key leaf); failed scan and plain keys show none
    assert.same({ "  10", "  2" }, counts)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("keeps the stamped count while the group's own scan is in flight", function()
    -- scan_group resets children to {} and renders before the first SCAN
    -- page lands: the display must not flash 0 over a valid stamp
    local buf = vim.api.nvim_create_buf(false, true)
    local db = tree.make_db_node({ db = 0 }, "c")
    local loading = tree.make_group_node("bench", "c", 0)
    loading.children = {}
    loading.loading = true
    loading._child_count = 10
    db.children = { loading }
    db.expanded = true
    tree.display_root = db
    tree.header_lines = { "", "----------------" }
    tree.render_tree(buf, {}, { db })
    tree.display_root = nil

    local ns = vim.api.nvim_create_namespace("poste_redis_browser")
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    local counts = {}
    for _, m in ipairs(marks) do
      if m[4].virt_text then counts[#counts + 1] = m[4].virt_text[1][1] end
    end
    assert.same({ "  10" }, counts)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
