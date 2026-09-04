--- browser actions spec — P1-4 write actions (TTL / delete / rename).
--- Transport stubbed: session_conn.execute + vim.fn.confirm + vim.ui.input
--- are replaced so specs never touch a real redis or block on a dialog.
local actions = require("poste-redis.browser.actions")
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
    local deleted = false
    actions.delete_key(node, {})
    assert.is_true(wait_for(function() return #calls >= 1 end))
    assert.same({ "DEL", "user:1" }, calls[1].cmd)
    assert.equals(0, calls[1].opts.db)
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
    assert.equals("user:*", scan.cmd[4])  -- SCAN 0 MATCH user:* COUNT 1000
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
end)
