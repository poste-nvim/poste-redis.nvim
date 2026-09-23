--- browser actions spec — P1-4 write actions (TTL / delete / rename).
--- Transport stubbed: session_conn.execute + vim.fn.confirm + vim.ui.input
--- are replaced so specs never touch a real redis or block on a dialog.
local actions = require("poste-redis.browser.actions")
local M = actions
local session_conn = require("poste-redis.session_conn")
local tree = require("poste-redis.browser.tree")

describe("poste-redis browser actions", function()
  local orig_execute
  local orig_confirm
  local orig_input
  local calls
  local confirm_answer

  before_each(function()
    orig_execute = session_conn.execute
    orig_confirm = vim.fn.confirm
    orig_input = vim.ui.input
    calls = {}
    confirm_answer = 1  -- default: yes
    session_conn.execute = function(conn_url, cmd, cbs, bufnr, opts)
      calls[#calls + 1] = { cmd = cmd, opts = opts }
      -- auto-respond so chains make progress
      if cbs and cbs.on_response then
        vim.schedule(function()
          -- SCAN estimate → keys array + cursor; DEL → count; TTL/EXISTS → value
          local name = (cmd[1] or ""):upper()
          if name == "SCAN" then
            cbs.on_response({ value = { value = { "user:1", "user:2" }, cursor = "0" } })
          elseif name == "DEL" then
            cbs.on_response({ value = { value = #cmd - 1 } })
          elseif name == "TTL" then
            cbs.on_response({ value = { value = 120 } })
          elseif name == "EXISTS" then
            cbs.on_response({ value = { value = 0 } })
          elseif name == "EXPIRE" or name == "PERSIST" then
            cbs.on_response({ value = { value = 1 } })
          elseif name == "RENAME" then
            cbs.on_response({ value = { value = "OK" } })
          else
            cbs.on_response({ value = { value = "OK" } })
          end
        end)
      end
      return "dispatched"
    end
    vim.fn.confirm = function() return confirm_answer end
    vim.ui.input = function(opts, cb)
      calls[#calls + 1] = { input_opts = opts }
      if cb then
        -- TTL prompts expect seconds; rename expects a key name
        local answer = (opts and opts.prompt and opts.prompt:find("TTL")) and "60" or "newkey"
        cb(answer)
      end
    end
  end)

  after_each(function()
    session_conn.execute = orig_execute
    vim.fn.confirm = orig_confirm
    vim.ui.input = orig_input
    require("poste-redis.history").clear()
  end)

  local function key_node(key, conn, db)
    return tree.make_key_node(key, conn, db, { type = "string" })
  end

  local function wait_for(fn)
    return vim.wait(500, fn, 5)
  end

  it("delete_key confirms then DELs the key", function()
    local node = key_node("user:1", "my-redis", 0)
    node.meta.url = "redis://h:6379/0"
    actions.delete_key(node, {})
    assert.is_true(wait_for(function() return #calls >= 1 end))
    assert.same({ "DEL", "user:1" }, calls[1].cmd)
    assert.equals(0, calls[1].opts.db)
  end)

  it("delete_key records a quoted command for keys containing whitespace", function()
    -- Regression: history lines were raw space-joins, so a key `a b` recorded
    -- as `DEL a b` — ambiguous on display and copy (reads back as two keys).
    local history = require("poste-redis.history")
    history.clear()
    local node = key_node("weird key", "my-redis", 0)
    node.meta.url = "redis://h:6379/0"
    actions.delete_key(node, {})
    assert.is_true(wait_for(function() return history.count() > 0 end))
    assert.equals('DEL "weird key"', history.list()[1].command)
  end)

  it("delete_key skips the DEL when the user cancels", function()
    confirm_answer = 2
    local node = key_node("user:1", "my-redis", 0)
    node.meta.url = "redis://h:6379/0"
    actions.delete_key(node, {})
    vim.wait(200, function() return false end, 5)
    assert.equals(0, #calls)  -- confirm failed → no server call
  end)

  it("delete_prefix estimates with SCAN MATCH then DELs each key", function()
    local group = tree.make_group_node("user", "my-redis", 0)
    group.meta.url = "redis://h:6379/0"
    actions.delete_prefix(group, {})
    assert.is_true(wait_for(function()
      local dels = 0
      for _, c in ipairs(calls) do if c.cmd[1] == "DEL" then dels = dels + 1 end end
      return dels >= 2
    end))
    local scan = calls[1]
    assert.equals("SCAN", scan.cmd[1])
    assert.equals("user:*", scan.cmd[6])  -- SCAN <cursor> COUNT 1000 MATCH user:*
    local dels = 0
    for _, c in ipairs(calls) do if c.cmd[1] == "DEL" then dels = dels + 1 end end
    assert.equals(2, dels)
  end)

  it("delete_prefix counts a key SCAN returns twice only once", function()
    -- SCAN is at-least-once: a rehash mid-walk can hand out the same key on a
    -- later page. It must not inflate the confirm estimate or DEL twice.
    local scan_pages = 0
    session_conn.execute = function(conn_url, cmd, cbs, bufnr, opts)
      calls[#calls + 1] = { cmd = cmd, opts = opts }
      local name = (cmd[1] or ""):upper()
      vim.schedule(function()
        if name == "SCAN" then
          scan_pages = scan_pages + 1
          if scan_pages == 1 then
            cbs.on_response({ value = { value = { "user:1", "user:2" }, cursor = "5" } })
          else
            cbs.on_response({ value = { value = { "user:1" }, cursor = "0" } })
          end
        elseif name == "DEL" then
          cbs.on_response({ value = { value = 1 } })
        else
          cbs.on_response({ value = { value = "OK" } })
        end
      end)
      return "dispatched"
    end
    local question
    vim.fn.confirm = function(q) question = q; return 1 end
    local group = tree.make_group_node("user", "stubconn", 0)
    group.meta.url = "redis://h:6379/0"
    actions.delete_prefix(group, {})
    assert.is_true(wait_for(function()
      return (question or ""):find("2") ~= nil
    end))
    local del_keys = {}
    for _, c in ipairs(calls) do
      if c.cmd[1] == "DEL" then del_keys[#del_keys + 1] = c.cmd[2] end
    end
    assert.same({ "user:1", "user:2" }, del_keys)
  end)

  it("delete_prefix loops SCAN pages before confirming (multi-page prefix)", function()
    -- a single estimate page undercounted prefixes with >1 page of keys and
    -- the delete silently missed the rest
    local scan_pages = 0
    session_conn.execute = function(conn_url, cmd, cbs, bufnr, opts)
      calls[#calls + 1] = { cmd = cmd, opts = opts }
      local name = (cmd[1] or ""):upper()
      vim.schedule(function()
        if name == "SCAN" then
          scan_pages = scan_pages + 1
          if scan_pages == 1 then
            cbs.on_response({ value = { value = { "user:1" }, cursor = "5" } })
          else
            cbs.on_response({ value = { value = { "user:2" }, cursor = "0" } })
          end
        elseif name == "DEL" then
          cbs.on_response({ value = { value = 1 } })
        else
          cbs.on_response({ value = { value = "OK" } })
        end
      end)
      return "dispatched"
    end
    local group = tree.make_group_node("user", "stubconn", 0)
    group.meta.url = "redis://h:6379/0"
    actions.delete_prefix(group, {})
    assert.is_true(wait_for(function()
      local dels = 0
      for _, c in ipairs(calls) do if c.cmd[1] == "DEL" then dels = dels + 1 end end
      return dels >= 2
    end), "keys from both SCAN pages must be deleted")
    local dels = 0
    for _, c in ipairs(calls) do if c.cmd[1] == "DEL" then dels = dels + 1 end end
    assert.equals(2, dels)
  end)

  it("delete_prefix cancels when the user declines the estimate confirm", function()
    confirm_answer = 2
    local group = tree.make_group_node("user", "my-redis", 0)
    group.meta.url = "redis://h:6379/0"
    actions.delete_prefix(group, {})
    vim.wait(300, function() return #calls >= 1 end, 5)
    -- SCAN ran (estimate), but no DEL followed
    assert.equals(1, #calls)
    assert.equals("SCAN", calls[1].cmd[1])
  end)

  it("set_ttl prompts and issues EXPIRE with the given seconds", function()
    local node = key_node("user:1", "my-redis", 0)
    node.meta.url = "redis://h:6379/0"
    actions.set_ttl(node, {})
    assert.is_true(wait_for(function()
      for _, c in ipairs(calls) do
        if type(c) == "table" and c.cmd and c.cmd[1] == "EXPIRE" then return true end
      end
      return false
    end))
    local expire = nil
    for _, c in ipairs(calls) do
      if type(c) == "table" and c.cmd and c.cmd[1] == "EXPIRE" then expire = c.cmd end
    end
    assert.is_not_nil(expire)
    assert.same({ "EXPIRE", "user:1", "60" }, expire)  -- input returned 60
    -- TTL was queried first
    assert.equals("TTL", calls[1].cmd[1])
  end)

  it("rename_key checks EXISTS then RENAMEs", function()
    local node = key_node("user:1", "my-redis", 0)
    node.meta.url = "redis://h:6379/0"
    actions.rename_key(node, {})
    assert.is_true(wait_for(function()
      for _, c in ipairs(calls) do
        if type(c) == "table" and c.cmd and c.cmd[1] == "RENAME" then return true end
      end
      return false
    end))
    local first_cmd = nil
    for _, c in ipairs(calls) do
      if type(c) == "table" and c.cmd then first_cmd = c.cmd; break end
    end
    assert.is_not_nil(first_cmd)
    assert.equals("EXISTS", first_cmd[1])
    local rename = nil
    for _, c in ipairs(calls) do
      if type(c) == "table" and c.cmd and c.cmd[1] == "RENAME" then rename = c.cmd end
    end
    assert.same({ "RENAME", "user:1", "newkey" }, rename)
  end)

  it("delete_prefix aggregates the batch into one history entry", function()
    local history = require("poste-redis.history")
    history.clear()
    local group = tree.make_group_node("user", "stubconn", 0)
    group.meta.url = "redis://h:6379/0"
    actions.delete_prefix(group, {})
    assert.is_true(wait_for(function() return history.count() > 0 end),
      "batch delete did not finish")
    local e = history.list()[1]
    assert.equals("DEL user:*", e.command, "one line for the whole batch")
    assert.equals(2, e.count)
    assert.truthy(e.yank:find("redis-cli --scan --pattern 'user:*'", 1, true),
      "yank must carry an executable pipeline, not a bare glob")
  end)

  it("delete_prefix yank survives a single quote in the prefix", function()
    -- a raw \'user\'s:*\' pipeline broke at the quote and pasted a broken
    -- shell line; the prefix is shell-single-quoted (POSIX \'\'\' escaping)
    local history = require("poste-redis.history")
    history.clear()
    local group = tree.make_group_node("user's", "stubconn", 0)
    group.meta.url = "redis://h:6379/0"
    actions.delete_prefix(group, {})
    assert.is_true(wait_for(function() return history.count() > 0 end),
      "batch delete did not finish")
    local e = history.list()[1]
    assert.truthy(e.yank:find("redis%-cli %-%-scan %-%-pattern 'user'\\''s:%*'", 1, false),
      "prefix quote must be escaped: " .. e.yank)
  end)

  it("delete_nodes aggregates the selection into one history entry", function()
    local history = require("poste-redis.history")
    history.clear()
    local key = key_node("user:1", "stubconn", 0)
    key.meta.url = "redis://h:6379/0"
    local group = tree.make_group_node("cache", "stubconn", 0)
    group.meta.url = "redis://h:6379/0"
    actions.delete_nodes({ key, group }, {})
    assert.is_true(wait_for(function() return history.count() > 0 end),
      "batch delete did not finish")
    local e = history.list()[1]
    assert.equals("DEL user:1 cache:*", e.command)
    assert.truthy(e.yank:find("DEL user:1", 1, true),
      "literal keys stay a plain DEL in the yank form")
    assert.truthy(e.yank:find("redis-cli --scan --pattern 'cache:*'", 1, true),
      "prefix globs yank as scan pipelines")
  end)

  it("delete_nodes runs each DEL against the owning node's db", function()
    -- multi-select is currently single-db, but the DEL loop must not
    -- silently depend on that: a key collected by a db-2 SCAN deleted with
    -- db-1 selected would hit an unrelated key (or nothing)
    local key_a = key_node("a:1", "stubconn", 1)
    key_a.meta.url = "redis://h:6379/0"
    local key_b = key_node("b:1", "stubconn", 2)
    key_b.meta.url = "redis://h:6379/0"
    actions.delete_nodes({ key_a, key_b }, {})
    assert.is_true(wait_for(function() return #calls >= 2 end),
      "batch delete did not finish")
    local dels = {}
    for _, c in ipairs(calls) do
      if type(c) == "table" and c.cmd and c.cmd[1] == "DEL" then
        dels[#dels + 1] = { key = c.cmd[2], db = c.opts.db }
      end
    end
    assert.equals(2, #dels)
    local by_key = {}
    for _, d in ipairs(dels) do by_key[d.key] = d.db end
    assert.equals(1, by_key["a:1"])
    assert.equals(2, by_key["b:1"])
  end)

  it("delete_key detaches only the deleted node (no db-wide rescan)", function()
    local parent = tree.make_group_node("user", "stubconn", 0)
    parent.meta.url = "redis://h:6379/0"
    parent.loaded = true
    local k1 = key_node("user:1", "stubconn", 0)
    local k2 = key_node("user:2", "stubconn", 0)
    k1.meta.url = "redis://h:6379/0"
    k1.parent, k2.parent = parent, parent
    parent.children = { k1, k2 }
    actions.delete_key(k1, {})
    assert.is_true(wait_for(function() return #parent.children == 1 end))
    assert.equals(k2, parent.children[1])
    for _, c in ipairs(calls) do
      if c.cmd then
        assert.not_equals("SCAN", c.cmd[1], "a single delete must not rescan the db")
      end
    end
  end)

  it("deleting a group's last key prunes the emptied loaded group", function()
    local db_node = tree.make_db_node({ db = 0 }, "stubconn")
    local parent = tree.make_group_node("user", "stubconn", 0)
    parent.loaded = true
    parent.parent = db_node
    local k1 = key_node("user:1", "stubconn", 0)
    k1.meta.url = "redis://h:6379/0"
    k1.parent = parent
    parent.children = { k1 }
    db_node.children = { parent }
    actions.delete_key(k1, {})
    assert.is_true(wait_for(function() return #(db_node.children or {}) == 0 end))
  end)

  it("set_ttl leaves the tree alone (EXPIRE never changes the keyspace)", function()
    local node = key_node("user:1", "stubconn", 0)
    node.meta.url = "redis://h:6379/0"
    actions.set_ttl(node, {})
    assert.is_true(wait_for(function()
      for _, c in ipairs(calls) do
        if c.cmd and c.cmd[1] == "EXPIRE" then return true end
      end
      return false
    end))
    vim.wait(100, function() return false end, 5)
    for _, c in ipairs(calls) do
      if c.cmd then
        assert.not_equals("SCAN", c.cmd[1], "TTL edit must not rescan the db")
      end
    end
  end)

  it("set_ttl_nodes EXPIREs every selected key after ONE prompt", function()
    local history = require("poste-redis.history")
    history.clear()
    local k1 = key_node("user:1", "stubconn", 0)
    local k2 = key_node("user:2", "stubconn", 0)
    k1.meta.url = "redis://h:6379/0"
    k2.meta.url = "redis://h:6379/0"
    local group = tree.make_group_node("user", "stubconn", 0)  -- skipped: not a key
    group.meta.url = "redis://h:6379/0"
    local done = false
    actions.set_ttl_nodes({ k1, group, k2 }, { on_done = function() done = true end })
    assert.is_true(wait_for(function() return done end))
    local expires = {}
    for _, c in ipairs(calls) do
      if c.cmd and c.cmd[1] == "EXPIRE" then expires[#expires + 1] = c.cmd end
    end
    assert.equals(2, #expires, "group nodes are skipped, keys get EXPIRE")
    assert.same({ "EXPIRE", "user:1", "60" }, expires[1])
    assert.same({ "EXPIRE", "user:2", "60" }, expires[2])
    -- one aggregated history line with both keys and an executable yank form
    assert.equals(1, history.count())
    assert.equals("EXPIRE user:1 user:2", history.list()[1].command)
    assert.equals(2, history.list()[1].count)
    -- render_command leaves clean tokens unquoted and quotes what needs it
    assert.match("redis%-cli EXPIRE user:1 60", history.list()[1].yank)
    assert.match("redis%-cli EXPIRE user:2 60", history.list()[1].yank)
  end)

  it("set_ttl_nodes yank line quotes a key with whitespace", function()
    -- a raw `redis-cli EXPIRE a b 60` read back as two keys; the quoted form
    -- keeps one key per line
    vim.ui.input = function(opts, cb) cb("60") end
    local history = require("poste-redis.history")
    history.clear()
    local done = false
    local node = key_node("we ird", "stubconn", 0)
    node.meta.url = "redis://h:6379/0"
    M.set_ttl_nodes({ node }, { on_done = function() done = true end })
    assert.is_true(wait_for(function() return done end))
    local e = history.list()[1]
    assert.match('redis%-cli EXPIRE "we ird" 60', e.yank)
  end)

  it("set_ttl_nodes with a negative prompt PERSISTs every selected key", function()
    -- the input stub answers "60" to TTL prompts; override to -1 for this case
    vim.ui.input = function(opts, cb)
      calls[#calls + 1] = { input_opts = opts }
      if cb then cb("-1") end
    end
    local k1 = key_node("user:1", "stubconn", 0)
    k1.meta.url = "redis://h:6379/0"
    actions.set_ttl_nodes({ k1 }, {})
    assert.is_true(wait_for(function()
      for _, c in ipairs(calls) do
        if c.cmd and c.cmd[1] == "PERSIST" then return true end
      end
      return false
    end))
  end)

  it("set_ttl_nodes warns when nothing selectable is in the selection", function()
    local group = tree.make_group_node("user", "stubconn", 0)
    group.meta.url = "redis://h:6379/0"
    actions.set_ttl_nodes({ group }, {})
    vim.wait(100, function() return false end, 5)
    for _, c in ipairs(calls) do
      assert.not_equals("EXPIRE", c.cmd and c.cmd[1], "no keys selected → no server call")
    end
  end)

  -- A key whose name is not valid UTF-8 reaches Lua as a rendering of its
  -- bytes — `(binary) N bytes hex: …` through the value path (SCAN's key list)
  -- or `hex:…` where a name is rendered. Writing it back addresses a key with
  -- THAT TEXT as its name: DEL answers 0 (so "Deleted … (0 key(s))") and
  -- EXPIRE answers 0 while the panel reports success and detaches the row.
  describe("writes on a key whose name only renders", function()
    local notices
    local orig_notify
    local BIN = "(binary) 2 bytes hex: ff 00"
    local HEXNAME = "hex:ff fe"

    before_each(function()
      orig_notify = vim.notify
      notices = {}
      vim.notify = function(msg) notices[#notices + 1] = tostring(msg) end
    end)
    after_each(function() vim.notify = orig_notify end)

    local function any_cmd(...)
      local wanted = { ... }
      for _, c in ipairs(calls) do
        if type(c) == "table" and c.cmd then
          for _, w in ipairs(wanted) do
            if c.cmd[1] == w then return true end
          end
        end
      end
      return false
    end

    local function notice_matching(pattern)
      for _, n in ipairs(notices) do
        if n:find(pattern) then return n end
      end
      return nil
    end

    for _, marker in ipairs({ { BIN, "SCAN-list rendering" }, { HEXNAME, "name rendering" } }) do
      local name = marker[1]
      it("delete_key refuses " .. marker[2], function()
        local node = key_node(name, "stubconn", 0)
        node.meta.url = "redis://h:6379/0"
        actions.delete_key(node, {})
        vim.wait(150, function() return false end, 5)
        assert.is_false(any_cmd("DEL"), "no DEL against a name that is only a rendering")
        assert.is_true(notice_matching("not the name") ~= nil,
          "the notice must say why: " .. table.concat(notices, " / "))
      end)

      it("set_ttl refuses " .. marker[2], function()
        local node = key_node(name, "stubconn", 0)
        node.meta.url = "redis://h:6379/0"
        actions.set_ttl(node, {})
        vim.wait(150, function() return false end, 5)
        assert.is_false(any_cmd("TTL", "EXPIRE", "PERSIST"),
          "not even the current-TTL query runs")
        assert.is_true(notice_matching("not the name") ~= nil)
      end)

      it("rename_key refuses " .. marker[2] .. " before prompting", function()
        local node = key_node(name, "stubconn", 0)
        node.meta.url = "redis://h:6379/0"
        actions.rename_key(node, {})
        vim.wait(150, function() return false end, 5)
        -- vim.ui.input records into `calls` too, so this covers "no prompt"
        assert.equals(0, #calls)
        assert.is_true(notice_matching("not the name") ~= nil)
      end)

      it("delete_prefix refuses " .. marker[2] .. " before its estimate SCAN", function()
        local group = tree.make_group_node(name, "stubconn", 0)
        group.meta.url = "redis://h:6379/0"
        actions.delete_prefix(group, {})
        vim.wait(150, function() return false end, 5)
        assert.equals(0, #calls, "the estimate SCAN must not run either")
        assert.is_true(notice_matching("not the name") ~= nil)
      end)
    end

    it("delete_nodes skips only the unaddressable keys", function()
      local good = key_node("user:1", "stubconn", 0)
      good.meta.url = "redis://h:6379/0"
      local bad = key_node(BIN, "stubconn", 0)
      bad.meta.url = "redis://h:6379/0"
      actions.delete_nodes({ good, bad }, {})
      assert.is_true(wait_for(function() return any_cmd("DEL") end), "batch delete stalled")
      vim.wait(150, function() return false end, 5)
      local dels = {}
      for _, c in ipairs(calls) do
        if c.cmd and c.cmd[1] == "DEL" then dels[#dels + 1] = c.cmd[2] end
      end
      assert.same({ "user:1" }, dels)
      assert.is_true(notice_matching("1 selected") ~= nil,
        "the skip must be reported: " .. table.concat(notices, " / "))
    end)

    it("set_ttl_nodes skips only the unaddressable keys", function()
      local good = key_node("user:1", "stubconn", 0)
      good.meta.url = "redis://h:6379/0"
      local bad = key_node(HEXNAME, "stubconn", 0)
      bad.meta.url = "redis://h:6379/0"
      actions.set_ttl_nodes({ good, bad }, {})
      assert.is_true(wait_for(function() return any_cmd("EXPIRE") end), "batch TTL stalled")
      vim.wait(150, function() return false end, 5)
      local expires = {}
      for _, c in ipairs(calls) do
        if c.cmd and c.cmd[1] == "EXPIRE" then expires[#expires + 1] = c.cmd[2] end
      end
      assert.same({ "user:1" }, expires)
      assert.is_true(notice_matching("1 selected") ~= nil)
    end)

    it("over-fire control: technical-looking names stay writable", function()
      -- the marker wants whole hex pairs after `hex:`, so a plain UTF-8 key
      -- that merely looks like one is not caught by the guard
      for _, name in ipairs({ "hex:zz", "hex:ffzz", "binary:key", "id:7" }) do
        calls = {}
        local node = key_node(name, "stubconn", 0)
        node.meta.url = "redis://h:6379/0"
        actions.delete_key(node, {})
        assert.is_true(wait_for(function() return any_cmd("DEL") end),
          name .. " must still delete")
        assert.same({ "DEL", name }, calls[1].cmd)
      end
    end)
  end)

  ------------------------------------------------------------------
  -- A rejected write has to leave the same trace a rejected `.redis`
  -- command leaves (a ✗ row in the sidebar, the server's message on
  -- activate). A notify line is gone as soon as the command line
  -- redraws, so without a record the only evidence that `RENAME` was
  -- tried and refused is gone. The record sites split by what the call
  -- could have changed: a failed mutation records, a failed read probe
  -- (the estimate SCAN, the EXISTS/TTL pre-checks) does not — nothing
  -- changed, and a ✗ row for it would claim otherwise.
  ------------------------------------------------------------------
  describe("failed writes reach the history, failed probes do not", function()
    local history = require("poste-redis.history")
    -- what a real server says when the connection is a replica
    local RO = "READONLY You can't write against a read only replica."
    local notices, orig_notify

    before_each(function()
      orig_notify = vim.notify
      notices = {}
      vim.notify = function(msg) notices[#notices + 1] = tostring(msg) end
      -- Drain whatever the previous test left scheduled: its batch chains
      -- (SCAN → DEL → record) can still be mid-flight, and would otherwise
      -- push rows into the history and command log asserted on below.
      vim.wait(150, function() return false end, 5)
      history.clear()
      calls = {}
    end)
    after_each(function() vim.notify = orig_notify end)

    --- Wrap the transport so a command matching `pred` answers on_error
    --- (deferred, like a real round trip) instead of the shared auto-response.
    local function fail_when(pred, msg)
      local inner = session_conn.execute
      session_conn.execute = function(conn_url, cmd, cbs, bufnr, opts)
        if not pred(cmd) then return inner(conn_url, cmd, cbs, bufnr, opts) end
        calls[#calls + 1] = { cmd = cmd, opts = opts }
        vim.schedule(function()
          if cbs and cbs.on_error then cbs.on_error(msg) end
        end)
        return "dispatched"
      end
    end

    local function dispatched(verb, arg)
      for _, c in ipairs(calls) do
        if c.cmd and c.cmd[1] == verb and (arg == nil or c.cmd[2] == arg) then return true end
      end
      return false
    end

    local function notice_matching(pattern)
      for _, n in ipairs(notices) do
        if n:find(pattern, 1, true) then return n end
      end
      return nil
    end

    --- The entry the rejected write must have left behind, or a failure.
    local function recorded()
      assert.is_true(wait_for(function() return history.count() > 0 end),
        "the rejected write left no history entry")
      return history.list()[1]
    end

    local function settled()
      vim.wait(150, function() return false end, 5)
    end

    it("rejected DEL records one entry with the server's reason", function()
      fail_when(function(c) return c[1] == "DEL" end, RO)
      local parent = tree.make_group_node("user", "my-redis", 0)
      parent.meta.url = "redis://h:6379/0"
      parent.loaded = true
      local k1 = key_node("user:1", "my-redis", 0)
      local k2 = key_node("user:2", "my-redis", 0)
      k1.meta.url, k2.meta.url = "redis://h:6379/0", "redis://h:6379/0"
      k1.parent, k2.parent = parent, parent
      parent.children = { k1, k2 }
      actions.delete_key(k1, {})
      local e = recorded()
      assert.equals("DEL user:1", e.command)
      assert.equals("write", e.kind)
      assert.equals("error", e.status)
      assert.equals(RO, e.error)
      assert.equals(1, history.count(), "one line, not a success line plus a failure line")
      -- the row survives: the server refused, so the keyspace is untouched
      assert.equals(2, #parent.children)
    end)

    it("rejected RENAME records the attempted command, not the outcome", function()
      fail_when(function(c) return c[1] == "RENAME" end, "ERR no such key for RENAME")
      local node = key_node("user:1", "my-redis", 0)
      node.meta.url = "redis://h:6379/0"
      actions.rename_key(node, {})
      local e = recorded()
      assert.equals("RENAME user:1 newkey", e.command)
      assert.equals("error", e.status)
      assert.equals("ERR no such key for RENAME", e.error)
    end)

    it("a failed EXISTS pre-check records nothing and never renames", function()
      fail_when(function(c) return c[1] == "EXISTS" end, "Connection refused by redis")
      local node = key_node("user:1", "my-redis", 0)
      node.meta.url = "redis://h:6379/0"
      actions.rename_key(node, {})
      settled()
      assert.is_false(dispatched("RENAME"), "the write must not run after a failed probe")
      assert.equals(0, history.count())
    end)

    it("rejected EXPIRE records; a failed TTL pre-check records nothing", function()
      fail_when(function(c) return c[1] == "EXPIRE" end, RO)
      local node = key_node("user:1", "my-redis", 0)
      node.meta.url = "redis://h:6379/0"
      actions.set_ttl(node, {})
      local e = recorded()
      assert.equals("EXPIRE user:1 60", e.command)
      assert.equals("error", e.status)
      assert.equals(RO, e.error)

      history.clear()
      calls = {}
      fail_when(function(c) return c[1] == "TTL" end, "Connection refused by redis")
      actions.set_ttl(node, {})
      settled()
      assert.is_false(dispatched("EXPIRE"), "no write after the read probe failed")
      assert.equals(0, history.count())
    end)

    it("partial prefix delete records one line that says how many survived", function()
      -- the shared SCAN hands back user:1 and user:2; only the first DEL fails
      fail_when(function(c) return c[1] == "DEL" and c[2] == "user:1" end, RO)
      local group = tree.make_group_node("user", "stubconn", 0)
      group.meta.url = "redis://h:6379/0"
      actions.delete_prefix(group, {})
      local e = recorded()
      assert.equals("DEL user:*", e.command)
      assert.equals(2, e.count, "count stays the batch size, not the deleted size")
      assert.equals("error", e.status)
      assert.equals("1 of 2 key(s) not deleted: " .. RO, e.error)
      assert.is_true(notice_matching("Deleted 1/2 key(s) under user:*") ~= nil,
        "the notice must not claim a clean run: " .. table.concat(notices, " / "))
    end)

    it("a failed estimate SCAN records nothing and deletes nothing", function()
      fail_when(function(c) return c[1] == "SCAN" end, "Connection refused by redis")
      local group = tree.make_group_node("user", "stubconn", 0)
      group.meta.url = "redis://h:6379/0"
      actions.delete_prefix(group, {})
      settled()
      assert.is_false(dispatched("DEL"))
      assert.equals(0, history.count())
    end)

    it("partial delete_nodes records one line that says how many survived", function()
      fail_when(function(c) return c[1] == "DEL" and c[2] == "a:1" end, RO)
      local a = key_node("a:1", "stubconn", 0)
      local b = key_node("b:1", "stubconn", 0)
      a.meta.url, b.meta.url = "redis://h:6379/0", "redis://h:6379/0"
      actions.delete_nodes({ a, b }, {})
      local e = recorded()
      assert.equals("DEL a:1 b:1", e.command)
      assert.equals(2, e.count)
      assert.equals("error", e.status)
      assert.equals("1 of 2 key(s) not deleted: " .. RO, e.error)
    end)

    it("delete_nodes reports a group whose scan died and keeps its row", function()
      -- The batch can only delete what SCAN collected. Without the note the
      -- ledger said "Deleted 1 key(s) across 2 node(s)" for a selection whose
      -- second node was never even counted, and dropping its row hid the keys
      -- that were still in the keyspace.
      fail_when(function(c) return c[1] == "SCAN" end, "Connection refused by redis")
      local db_node = tree.make_db_node({ db = 0 }, "stubconn")
      local key = key_node("user:1", "stubconn", 0)
      local group = tree.make_group_node("cache", "stubconn", 0)
      key.meta.url, group.meta.url = "redis://h:6379/0", "redis://h:6379/0"
      key.parent, group.parent = db_node, db_node
      db_node.children = { key, group }
      local question
      vim.fn.confirm = function(q) question = q; return 1 end
      actions.delete_nodes({ key, group }, { db_node = db_node })
      local e = recorded()
      assert.equals("DEL user:1 cache:*", e.command)
      assert.equals(1, e.count, "only the collected key counts as the batch")
      assert.equals("error", e.status)
      assert.equals("1 of 2 node(s) not scanned: Connection refused by redis", e.error)
      assert.is_true(dispatched("DEL", "user:1"), "the collected key still gets deleted")
      assert.is_true((question or ""):find("could not be scanned") ~= nil,
        "the confirm must not quote a count the user cannot trust: " .. tostring(question))
      assert.equals(group, db_node.children[1], "the unscanned node keeps its row")
      -- the yank line for the failed node is exactly the retry command
      assert.truthy(e.yank:find("redis-cli --scan --pattern 'cache:*'", 1, true))
    end)

    it("partial set_ttl_nodes records one line that says how many were set", function()
      fail_when(function(c) return c[1] == "EXPIRE" and c[2] == "user:1" end, RO)
      local k1 = key_node("user:1", "stubconn", 0)
      local k2 = key_node("user:2", "stubconn", 0)
      k1.meta.url, k2.meta.url = "redis://h:6379/0", "redis://h:6379/0"
      actions.set_ttl_nodes({ k1, k2 }, {})
      local e = recorded()
      assert.equals("EXPIRE user:1 user:2", e.command)
      assert.equals(2, e.count)
      assert.equals("error", e.status)
      assert.equals("1 of 2 key(s) not set: " .. RO, e.error)
      assert.is_true(notice_matching("TTL set on 1/2 key(s)") ~= nil,
        "the notice must not claim a clean run: " .. table.concat(notices, " / "))
    end)

    it("a clean run still records no error row", function()
      local group = tree.make_group_node("user", "stubconn", 0)
      group.meta.url = "redis://h:6379/0"
      actions.delete_prefix(group, {})
      local e = recorded()
      assert.equals("", e.status, "history.push normalizes a missing status to \"\"")
      assert.is_nil(e.error)
    end)
  end)
end)
