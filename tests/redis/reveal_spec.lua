--- reveal spec — opening the browser tree at a specific key: dataset `gd`,
--- :PosteRedisReveal and .redis `gd` all funnel into browser.reveal, which
--- re-scopes the browser (connection + db) and walks the folder path,
--- expanding lazy folders across renders until the key's row can be focused.
local async = require("poste-redis.browser.async")
local tree = require("poste-redis.browser.tree")

describe("poste-redis browser reveal", function()
  local browser = require("poste-redis.browser.init")
  local session_conn = require("poste-redis.session_conn")
  local connections = require("poste-redis.connections")

  local orig_load, orig_execute, orig_resolve, orig_notify
  before_each(function()
    orig_load = async.load_connections
    orig_execute = session_conn.execute
    orig_resolve = connections.resolve_redis_url
    orig_notify = vim.notify
    vim.notify = function() end  -- keep reveal's toasts out of the runner log
    -- browser state is module-global: every test starts fresh
    browser._test.reset_scope()
    browser.close()
    async.set_view_mode("flatten")
    connections.resolve_redis_url = function(name)
      if name == "stub" then return "redis://127.0.0.1:16479/0", nil end
      return nil, "unknown connection: " .. tostring(name)
    end
    async.load_connections = function(cb)
      cb({ tree.make_connection_node({
        name = "stub", url = "redis://127.0.0.1:16479/0", dialect = "redis",
      }) })
    end
    session_conn.execute = function(_, _, cbs)
      if cbs and cbs.on_response then
        cbs.on_response({ value = {
          value = { "user:1", "user:2", "plain", "cache:a" }, cursor = "0",
        } })
      end
      return "dispatched"
    end
  end)
  after_each(function()
    vim.notify = orig_notify
    async.load_connections = orig_load
    session_conn.execute = orig_execute
    connections.resolve_redis_url = orig_resolve
    browser.close()
  end)

  --- The tree node the browser cursor sits on, once the walk finishes.
  local function wait_revealed()
    assert.is_true(vim.wait(2000, function()
      return browser._test.reveal_state() == nil
    end, 5), "the reveal walk did not finish")
    local win = browser.info().window
    local cur = vim.api.nvim_win_get_cursor(win)[1]
    return browser._test.line_to_node()[cur - tree.HEADER_LINES], cur
  end

  it("lands on the key's row and opens the folder above it", function()
    browser.reveal({ key = "user:1", connection = "stub", db = 0 })
    local node, cur = wait_revealed()
    assert.equals("key", node.node_type)
    assert.equals("user:1", node.meta.key)
    -- some folder row for `user` renders above the key (rows of sibling
    -- keys may sit directly above; the folder itself must be up there too)
    local l2n = browser._test.line_to_node()
    local parent
    for i = cur - tree.HEADER_LINES - 1, 1, -1 do
      if l2n[i] and l2n[i].node_type == "group" then parent = l2n[i] break end
    end
    assert.equals("user", parent and parent.name, "the user folder must sit above the key")
    assert.is_true(parent.expanded)
    assert.equals(0, browser.current_scope().db)
  end)

  it("walks folded lazy spines in nested view", function()
    async.set_view_mode("nested")
    session_conn.execute = function(_, _, cbs)
      if cbs and cbs.on_response then
        cbs.on_response({ value = {
          value = { "a:b:c1", "a:b:c2", "a:b:c3" }, cursor = "0",
        } })
      end
      return "dispatched"
    end
    browser.reveal({ key = "a:b:c2", connection = "stub", db = 0 })
    local node = wait_revealed()
    assert.equals("key", node.node_type)
    assert.equals("a:b:c2", node.meta.key)
  end)

  it("re-scopes to the requested connection + db", function()
    -- first open lands on db 0 via the picker; reveal asks for db 2
    browser.open()
    assert.is_true(vim.wait(2000, function()
      local l = vim.api.nvim_buf_get_lines(browser.info().buffer, 0, -1, false)
      return #l > 2 and l[1]:find("Select a connection", 1, true) ~= nil
    end, 5), "picker did not render")
    browser._test.choose_connection()
    assert.equals(0, browser.current_scope().db)

    browser.reveal({ key = "plain", connection = "stub", db = 2 })
    local node = wait_revealed()
    assert.equals("stub", browser.current_scope().connection)
    assert.equals(2, browser.current_scope().db)
    assert.equals("plain", node.meta.key)
  end)

  it("re-revealing in an already expanded tree costs no full render", function()
    browser.reveal({ key = "user:1", connection = "stub", db = 0 })
    wait_revealed()
    local renders = 0
    local orig = async.render_hook
    async.render_hook = function()
      renders = renders + 1
      orig()
    end
    -- the user folder is already expanded and user:2 already on screen:
    -- the walk descends without expanding anything, so no render is needed
    browser.reveal({ key = "user:2", connection = "stub", db = 0 })
    local node = wait_revealed()
    async.render_hook = orig
    assert.equals("user:2", node.meta.key)
    assert.equals(0, renders, "an already-materialized path must not re-render")
  end)

  it("gives up with a notice when the key is not in the tree", function()
    local notified
    vim.notify = function(msg) notified = msg end
    browser.reveal({ key = "nope:missing", connection = "stub", db = 0 })
    assert.is_true(vim.wait(2000, function()
      return browser._test.reveal_state() == nil
    end, 5), "the walk must terminate")
    assert.match("not found", notified or "")
  end)
  it("reveal to another db while search results are shown re-walks the NEW scope", function()
    -- Regression: reveal.start parked the reveal state BEFORE clearing the
    -- search; clear's render resumed the walk against the OLD scope's tree
    -- and cleared the walk, so the final scope never got walked.
    browser.open({ connection = { name = "stub", url = "redis://127.0.0.1:16479/0" } })
    local bst = require("poste-redis.browser.state")
    assert.is_true(vim.wait(2000, function()
      return bst.current_db_node and bst.current_db_node.children
        and #bst.current_db_node.children > 0
    end, 5), "db 0 scan did not finish")

    -- active search results replace the tree on db 0
    async.search(bst.current_db_node, "redis://127.0.0.1:16479/0", "stub", "user")
    assert.is_true(vim.wait(2000, function()
      return bst.current_db_node._search_results ~= nil
        and bst.current_db_node._search_results.loading == false
    end, 5), "search results did not finish")

    -- reveal the same-named key under db 1: only the NEW scope's walk is valid
    browser.reveal({ key = "cache:a", connection = "stub", db = 1 })
    local node = wait_revealed()
    assert.equals("key", node.node_type)
    assert.equals("cache:a", node.meta.key)
    assert.equals(1, node.meta.db, "the revealed node must live in the requested db")
    assert.equals(1, browser.current_scope().db)
  end)
end)

describe("poste-redis reveal entry points", function()
  local buffer = require("poste-redis.buffer")

  after_each(function()
    buffer.close()
    pcall(vim.api.nvim_buf_delete, 0, { force = false })
  end)

  it("gd on a .redis command reveals its key under the file's own context", function()
    local browser = require("poste-redis.browser.init")
    local revealed
    browser.reveal = function(opts)
      revealed = opts
      return true
    end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# comment",
      "USE stub",
      "SELECT 3",
      "GET user:1",
    })
    vim.bo[buf].filetype = "poste_redis"
    require("poste-redis.buffer_setup").setup_buffer_keymaps(buf)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    vim.fn.feedkeys("gd", "x")
    vim.api.nvim_set_current_buf(buf)  -- feedkeys may have left the buffer

    assert.truthy(revealed, "gd did not trigger a reveal")
    assert.equals("user:1", revealed.key)
    assert.equals("stub", revealed.connection)
    assert.equals(3, revealed.db)
  end)
end)
