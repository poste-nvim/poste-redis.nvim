--- searchbar spec — the browser's search input: query parsing (the icon is
--- virt text, never buffer text, but a stray one must not leak into a
--- query), the cursor clamp onto the pinned header rows, and the
--- commit/cancel state machine driven directly (not through <CR>, which
--- would need a real insert-mode session). async.search and the render hook
--- are patched on the loaded modules and restored, the same way other specs
--- stub module fields.
local browser_state = require("poste-redis.browser.state")
local tree = require("poste-redis.browser.tree")
local async = require("poste-redis.browser.async")

describe("poste-redis browser searchbar", function()
  local searchbar = require("poste-redis.browser.searchbar")
  local orig_notify, notes

  --- A scratch browser buffer laid out like the real thing (bar, separator,
  --- tree rows) displayed in a floating window, wired into browser state.
  local function make_browser(lines)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local win = vim.api.nvim_open_win(buf, false, {
      relative = "editor", width = 40, height = #lines, row = 0, col = 0,
    })
    browser_state.browser_buf = buf
    browser_state.browser_win = win
    return buf, win
  end

  before_each(function()
    orig_notify = vim.notify
    notes = {}
    vim.notify = function(msg) notes[#notes + 1] = msg end
  end)

  after_each(function()
    vim.notify = orig_notify
    if browser_state.browser_buf and vim.api.nvim_buf_is_valid(browser_state.browser_buf) then
      local win = vim.fn.bufwinid(browser_state.browser_buf)
      if win ~= -1 then pcall(vim.api.nvim_win_close, win, true) end
      pcall(vim.api.nvim_buf_delete, browser_state.browser_buf, { force = true })
    end
    browser_state.browser_buf = nil
    browser_state.browser_win = nil
    browser_state.search_active = false
    browser_state.search_query = ""
    browser_state.conn_picker.active = false
  end)

  describe("parse_line", function()
    it("trims whitespace", function()
      assert.equals("user:*", searchbar.parse_line("  user:*  "))
    end)

    it("strips one icon prefix, and repairs a doubled one", function()
      assert.equals("q", searchbar.parse_line(tree.SEARCH_PREFIX .. "q"))
      assert.equals("q", searchbar.parse_line(tree.SEARCH_PREFIX .. tree.SEARCH_PREFIX .. "q"))
    end)

    it("strips a bare icon with no separator space", function()
      assert.equals("q", searchbar.parse_line(tree.SEARCH_ICON .. "q"))
    end)

    it("keeps a hash and dashes inside the query", function()
      -- only a STANDALONE #/-- starts a comment; the bar is verbatim text
      assert.equals("user#1", searchbar.parse_line("user#1"))
      assert.equals("hash--tag", searchbar.parse_line("hash--tag"))
    end)

    it("tolerates nil and empty", function()
      assert.equals("", searchbar.parse_line(nil))
      assert.equals("", searchbar.parse_line(""))
    end)
  end)

  describe("clamp_cursor", function()
    it("walks the cursor from a pinned header row down to the first tree row", function()
      local _, win = make_browser({ "", "", "key:a", "key:b" })
      vim.api.nvim_win_set_cursor(win, { 1, 0 })
      searchbar.clamp_cursor()
      assert.equals(3, vim.api.nvim_win_get_cursor(win)[1])
    end)

    it("keeps an in-bounds column when walking down to the tree", function()
      local _, win = make_browser({ "xx", "", "ab" })
      vim.api.nvim_win_set_cursor(win, { 1, 1 })
      searchbar.clamp_cursor()
      local cur = vim.api.nvim_win_get_cursor(win)
      assert.equals(3, cur[1])
      assert.equals(1, cur[2])
    end)

    it("does nothing on an empty db (no tree row to park on)", function()
      local _, win = make_browser({ "", "" })
      vim.api.nvim_win_set_cursor(win, { 1, 0 })
      searchbar.clamp_cursor()
      assert.equals(1, vim.api.nvim_win_get_cursor(win)[1])
    end)

    it("leaves the tree rows alone and skips while the bar is being edited", function()
      local _, win = make_browser({ "", "", "key:a" })
      vim.api.nvim_win_set_cursor(win, { 3, 1 })
      searchbar.clamp_cursor()
      assert.equals(3, vim.api.nvim_win_get_cursor(win)[1])
      -- while the caret sits on the bar the clamp is lifted entirely
      browser_state.search_active = true
      vim.api.nvim_win_set_cursor(win, { 1, 2 })
      searchbar.clamp_cursor()
      assert.equals(1, vim.api.nvim_win_get_cursor(win)[1])
    end)
  end)

  describe("commit", function()
    local orig_search, search_calls, render_calls

    before_each(function()
      search_calls, render_calls = {}, {}
      orig_search = async.search
      async.search = function() search_calls[#search_calls + 1] = true end
      browser_state.render = function() render_calls[#render_calls + 1] = true end
      browser_state.current_conn = { name = "local", url = "redis://127.0.0.1:6379" }
      browser_state.current_db_node = { node_type = "db" }
    end)

    after_each(function()
      async.search = orig_search
      browser_state.render = nil
      browser_state.current_conn = nil
      browser_state.current_db_node = nil
    end)

    local function prime_bar(text)
      local buf = browser_state.browser_buf
      tree.set_header_line(buf, text, 1)
      browser_state.search_active = true
      -- the mappings enter() installs; commit deletes them unconditionally
      vim.keymap.set("i", "<CR>", function() end, { buffer = buf })
      vim.keymap.set("i", "<NL>", function() end, { buffer = buf })
      vim.keymap.set("i", "<Esc>", function() end, { buffer = buf })
    end

    it("commits the parsed query and runs the search", function()
      make_browser({ "", "", "key:a" })
      prime_bar("user:*")
      searchbar.commit()
      assert.equals("user:*", browser_state.search_query)
      assert.equals(1, #search_calls)
      assert.equals(1, #render_calls)
      assert.is_false(browser_state.search_active)
    end)

    it("an empty query clears instead of searching", function()
      make_browser({ "", "", "key:a" })
      prime_bar("   ")
      searchbar.commit()
      assert.equals("", browser_state.search_query)
      assert.equals(0, #search_calls)
      assert.is_false(browser_state.search_active)
    end)
  end)

  describe("cancel", function()
    it("drops the query and restores the idle state", function()
      make_browser({ "stale", "", "key:a" })
      local buf = browser_state.browser_buf
      browser_state.search_active = true
      browser_state.search_query = "stale"
      vim.keymap.set("i", "<CR>", function() end, { buffer = buf })
      vim.keymap.set("i", "<NL>", function() end, { buffer = buf })
      vim.keymap.set("i", "<Esc>", function() end, { buffer = buf })
      searchbar.cancel()
      assert.is_false(browser_state.search_active)
      assert.equals("", browser_state.search_query)
    end)
  end)
end)
