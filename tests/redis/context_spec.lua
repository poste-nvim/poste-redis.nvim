--- context spec — window-scoped context resolution + display.
--- Covers the pure per-file walk (entries_context), buffer-level file_context,
--- final display formatting, and the window priority chain in resolve():
--- result panel > browser > .redis file > global context.
local context = require("poste-redis.context")
local parser = require("poste-redis.parser")
local redis_state = require("poste-redis.state")

describe("poste-redis context", function()
  after_each(function()
    redis_state.context.connection = nil
    redis_state.context.db = nil
    redis_state.current_url = nil
  end)

  local function entries(content)
    return parser.extract_entries(content)
  end

  describe("entries_context", function()
    it("returns nil/nil for an empty or command-only file", function()
      local c = context.entries_context(entries(""), 1)
      assert.is_nil(c.connection)
      assert.is_nil(c.db)
      c = context.entries_context(entries("GET k\n"), 2)
      assert.is_nil(c.connection)
      assert.is_nil(c.db)
    end)

    it("picks the connection from the nearest USE above the cursor", function()
      local c = context.entries_context(entries("USE a\nGET 1\n"), 1)
      assert.equals("a", c.connection)
      c = context.entries_context(entries("USE a\nGET 1\n"), 2)
      assert.equals("a", c.connection)
    end)

    it("a bare USE unpins the connection back to nil", function()
      local c = context.entries_context(entries("USE a\nSELECT 3\nUSE\nGET x\n"), 4)
      assert.is_nil(c.connection)
      assert.is_nil(c.db)
    end)

    it("tracks the nearest SELECT for the db within the cursor's section", function()
      local c = context.entries_context(entries("USE a\nSELECT 3\nGET x\n"), 3)
      assert.equals("a", c.connection)
      assert.equals(3, c.db)
      -- SELECT 0 is a real db and must come through
      c = context.entries_context(entries("USE a\nSELECT 0\nGET x\n"), 3)
      assert.equals(0, c.db)
    end)

    it("SELECTs from an earlier USE section do not leak into the next", function()
      local es = entries("USE a\nSELECT 3\nGET x\nUSE b\nGET y\n")
      assert.equals("a", context.entries_context(es, 3).connection)
      assert.equals(3, context.entries_context(es, 3).db)
      local c = context.entries_context(es, 5)
      assert.equals("b", c.connection)
      assert.is_nil(c.db)
    end)

    it("later SELECTs override earlier ones", function()
      local c = context.entries_context(entries("SELECT 1\nSELECT 2\nGET x\n"), 3)
      assert.equals(2, c.db)
    end)

    it("sitting on a USE / SELECT previews what it establishes", function()
      assert.equals("a", context.entries_context(entries("USE a\n"), 1).connection)
      local c = context.entries_context(entries("USE a\nSELECT 3\n"), 2)
      assert.equals("a", c.connection)
      assert.equals(3, c.db)
    end)

    it("an unquoted SELECT arg that is not a number is ignored", function()
      local c = context.entries_context(entries("SELECT nope\nGET x\n"), 2)
      assert.is_nil(c.db)
    end)
  end)

  describe("file_context", function()
    it("resolves a buffer's context at a line", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "USE srv", "SELECT 2", "GET k" })
      local c = context.file_context(buf, 2)
      assert.equals("srv", c.connection)
      assert.equals(2, c.db)
      assert.is_nil(context.file_context(buf, 1).db)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  describe("display", function()
    it("formats connection + db", function()
      assert.equals("local db3", context.display({ connection = "local", db = 3 }))
      assert.equals("local db0", context.display({ connection = "local", db = 0 }))
      assert.equals("local", context.display({ connection = "local", db = nil }))
    end)

    it("shows the db alone when there is no connection", function()
      assert.equals("db2", context.display({ connection = nil, db = 2 }))
    end)

    it("empty when nothing is resolvable", function()
      assert.equals("", context.display({ connection = nil, db = nil }))
    end)

    it("a URL renders as its credential-free host", function()
      assert.equals("127.0.0.1:6379",
        context.display({ connection = "redis://127.0.0.1:6379/0", db = nil }))
      local ctx = context.display({
        connection = "redis://:secret@127.0.0.1:16379/0", db = 2,
      })
      assert.is_nil(ctx:find("secret"))
      assert.equals("127.0.0.1:16379 db2", ctx)
    end)
  end)

  describe("resolve", function()
    local function open_buf(lines)
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      return buf
    end

    it("a .redis buffer resolves its cursor context (USE + SELECT)", function()
      local buf = open_buf({ "USE srv", "SELECT 3", "GET k" })
      vim.api.nvim_buf_set_option(buf, "filetype", "poste_redis")
      vim.api.nvim_set_current_buf(buf)
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      assert.same({ connection = "srv", db = 3 }, context.resolve())
      -- moving above the SELECT scopes the db back away
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      assert.same({ connection = "srv", db = nil }, context.resolve())
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("a .redis buffer without USE falls back to the global context", function()
      redis_state.context.connection = "global"
      local buf = open_buf({ "SELECT 1", "GET k" })
      vim.api.nvim_buf_set_option(buf, "filetype", "poste_redis")
      vim.api.nvim_set_current_buf(buf)
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      assert.same({ connection = "global", db = 1 }, context.resolve())
      -- file USE wins over the global context
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "USE fileconn", "GET k" })
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      assert.same({ connection = "fileconn", db = nil }, context.resolve())
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("a .redis buffer with neither USE nor global context is empty", function()
      redis_state.context.connection = nil
      local buf = open_buf({ "GET k" })
      vim.api.nvim_buf_set_option(buf, "filetype", "poste_redis")
      vim.api.nvim_set_current_buf(buf)
      assert.same({ connection = nil, db = nil }, context.resolve())
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("non-poste windows show the global context", function()
      redis_state.context.connection = nil
      local buf = open_buf({ "hello" })
      vim.api.nvim_set_current_buf(buf)
      assert.same({ connection = nil, db = nil }, context.resolve())
      redis_state.context.connection = "local"
      assert.same({ connection = "local", db = nil }, context.resolve())
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("the result panel resolves the active tab's context", function()
      local bstate = require("poste-redis.buffer.state")
      local buf = open_buf({ "row" })
      local saved = {
        buf = bstate.buf, win = bstate.win, tabs = bstate.tabs, active = bstate.active,
      }
      bstate.buf = buf
      bstate.win = vim.api.nvim_get_current_win()
      bstate.tabs = { { kind = "text", meta = { connection = "panel", db = 5 } } }
      bstate.active = 1
      vim.api.nvim_set_current_buf(buf)
      assert.same({ connection = "panel", db = 5 }, context.resolve())
      bstate.buf, bstate.win, bstate.tabs, bstate.active =
        saved.buf, saved.win, saved.tabs, saved.active
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("the browser window resolves its current scope", function()
      local binit = require("poste-redis.browser.init")
      local orig = binit.current_scope
      binit.current_scope = function()
        return { connection = "browse", db = 7 }
      end
      local buf = open_buf({ "" })
      vim.api.nvim_buf_set_name(buf, "poste://redis_browser")
      vim.api.nvim_set_current_buf(buf)
      assert.same({ connection = "browse", db = 7 }, context.resolve())
      binit.current_scope = orig
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)
end)