--- header_bar spec — the pinned filter bar overlay: a borderless float
--- mirroring the browser buffer's header lines 1-2, anchored to the browser
--- window's top rows so the bar + separator stay visible while the tree
--- scrolls. The overlay is chrome only: the buffer lines stay the source of
--- truth, line math is untouched.
local async = require("poste-redis.browser.async")
local header_bar = require("poste-redis.browser.header_bar")
local tree = require("poste-redis.browser.tree")

describe("poste-redis browser header bar overlay", function()
  local browser = require("poste-redis.browser.init")
  local session_conn = require("poste-redis.session_conn")

  local orig_load, orig_execute
  before_each(function()
    orig_load = async.load_connections
    orig_execute = session_conn.execute
    -- browser state is module-global and persists across open/close: start
    -- every test at the true first-open state
    browser._test.reset_scope()
    -- flat view: one row per key (the overlay tests need tall, scrollable
    -- trees; grouping would collapse a single-prefix key set into one row)
    async.set_view_mode("flat")
  end)
  after_each(function()
    async.load_connections = orig_load
    session_conn.execute = orig_execute
    browser.close()
  end)

  -- stub a connection whose db holds `n` flat keys (SCAN returns one page)
  local function stub_keys(n)
    async.load_connections = function(cb)
      cb({ tree.make_connection_node({
        name = "stub", url = "redis://127.0.0.1:16479/0", dialect = "redis",
      }) })
    end
    session_conn.execute = function(_, _, cbs)
      if cbs and cbs.on_response then
        local keys = {}
        for i = 1, n do keys[i] = ("key:%03d"):format(i) end
        cbs.on_response({ value = { value = keys, cursor = "0" } })
      end
      return "dispatched"
    end
  end

  local function open_connected(n)
    stub_keys(n)
    browser.open()
    local buf = browser.info().buffer
    assert.is_true(vim.wait(2000, function()
      local l = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      return #l > 2 and l[1]:find("Select a connection", 1, true) ~= nil
    end, 5), "connections picker did not render")
    browser._test.choose_connection()
    assert.is_true(vim.wait(2000, function()
      return #vim.api.nvim_buf_get_lines(buf, 0, -1, false) > tree.HEADER_LINES + 3
    end, 5), "db scan did not render")
    return buf
  end

  it("pins a borderless float over the browser window's first text rows", function()
    local buf = open_connected(20)
    local win = browser.info().window
    local fwin = header_bar.float_win()
    assert.is_truthy(fwin, "overlay float was not created")

    local cfg = vim.api.nvim_win_get_config(fwin)
    assert.equals("win", cfg.relative)
    assert.equals(win, cfg.win, "overlay must be anchored to the browser window")
    -- relative="win" row 0 is the window's first TEXT row (the winbar is
    -- excluded from float anchoring): row 1 would land the overlay one row
    -- low — the bar duplicates on screen and real rows hide under it
    assert.equals(0, cfg.row, "overlay must pin to the first text row")
    assert.equals(0, cfg.col, "the browser window has no gutter: col 0 is text")
    assert.equals(tree.HEADER_LINES, cfg.height, "overlay mirrors the two header lines")
    assert.equals(vim.api.nvim_win_get_width(win), cfg.width)
    assert.is_false(cfg.focusable, "overlay must not steal focus")

    -- alignment on screen: the overlay's rows sit exactly on the buffer's
    -- header lines 1-2 (a 1-row offset here is the duplicated-bar bug)
    local fbuf = header_bar._test.state().buf
    for i = 1, tree.HEADER_LINES do
      local t = vim.fn.screenpos(win, i, 1)
      local f = vim.fn.screenpos(fwin, i, 1)
      assert.equals(t.row, f.row, "overlay row " .. i .. " not on buffer line " .. i)
      assert.equals(t.col, f.col, "overlay row " .. i .. " column misaligned")
    end
    -- mirror: buffer lines 1-2 (search bar + separator) are the source of truth
    assert.same(vim.api.nvim_buf_get_lines(buf, 0, tree.HEADER_LINES, false),
      vim.api.nvim_buf_get_lines(fbuf, 0, -1, false))
    -- the idle bar carries its icon as inline virt text (ghost hint with no
    -- query), and the separator row is grayed — both re-applied on the mirror
    local marks = vim.api.nvim_buf_get_extmarks(fbuf, tree._test.search_ns, 0, -1, {})
    assert.is_true(#marks >= 1, "search-bar icon was not mirrored onto the overlay")
    assert.equals(0, marks[1][2], "icon extmark must sit on the overlay's bar row")
    local sep_marks = vim.api.nvim_buf_get_extmarks(fbuf, tree._test.header_ns, 0, -1, {})
    assert.is_true(#sep_marks >= 1, "separator highlight was not mirrored")
  end)

  it("keeps the bar pinned while the tree scrolls under it", function()
    local buf = open_connected(60)
    local win = browser.info().window
    local fwin = header_bar.float_win()
    assert.is_truthy(fwin)

    vim.api.nvim_win_set_height(win, 10)
    vim.api.nvim_exec_autocmds("WinResized", {})  -- separator + overlay re-sync
    local before = vim.fn.screenpos(fwin, 1, 1)

    -- scroll the header rows out of the window's view
    vim.api.nvim_win_set_cursor(win, { 40, 0 })
    assert.is_true(vim.fn.line("w0", win) > tree.HEADER_LINES + 1,
      "test setup: the header rows should have scrolled off")

    -- the overlay is tied to the WINDOW, not the buffer text: same screen
    -- row, still showing the header lines
    local after = vim.fn.screenpos(fwin, 1, 1)
    assert.equals(before.row, after.row, "overlay moved with the scroll")
    assert.equals(before.col, after.col)
    local fbuf = header_bar._test.state().buf
    assert.same(vim.api.nvim_buf_get_lines(buf, 0, tree.HEADER_LINES, false),
      vim.api.nvim_buf_get_lines(fbuf, 0, -1, false))
  end)

  it("hides while the search bar is being edited and returns after commit", function()
    local buf = open_connected(5)
    assert.is_truthy(header_bar.float_win())

    browser._test.search_enter()
    local fwin = header_bar.float_win()
    assert.is_truthy(fwin, "overlay window must survive the edit (hidden, not closed)")
    assert.is_true(vim.api.nvim_win_get_config(fwin).hide,
      "editing puts the caret under the overlay — it must hide")

    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "key:001" })
    browser._test.search_commit()

    fwin = header_bar.float_win()
    assert.is_truthy(fwin, "overlay must come back after commit")
    assert.is_false(vim.api.nvim_win_get_config(fwin).hide)
    -- committed query is mirrored onto the bar row
    local fbuf = header_bar._test.state().buf
    assert.equals("key:001", vim.api.nvim_buf_get_lines(fbuf, 0, 1, false)[1])
  end)

  it("renders the picker hint without the search icon and follows resizes", function()
    stub_keys(0)
    browser.open()
    local buf = browser.info().buffer
    assert.is_true(vim.wait(2000, function()
      local l = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      return #l >= 2 and l[1]:find("Select a connection", 1, true) ~= nil
    end, 5), "connections picker did not render")

    local fbuf = header_bar._test.state().buf
    assert.is_truthy(fbuf, "overlay must exist in picker mode")
    assert.same(vim.api.nvim_buf_get_lines(buf, 0, tree.HEADER_LINES, false),
      vim.api.nvim_buf_get_lines(fbuf, 0, -1, false))
    -- plain chrome: no search icon on the hint row
    local marks = vim.api.nvim_buf_get_extmarks(fbuf, tree._test.search_ns, 0, -1, {})
    assert.equals(0, #marks, "picker hint must not carry the search icon")

    -- narrowing the split re-syncs the overlay width via WinResized
    local win = browser.info().window
    pcall(vim.api.nvim_win_set_width, win, 40)
    vim.api.nvim_exec_autocmds("WinResized", {})
    local cfg = vim.api.nvim_win_get_config(header_bar.float_win())
    assert.equals(40, cfg.width, "overlay width must follow the split")
  end)

  it("keeps the cursor off the pinned rows; the bar is <leader>/ only", function()
    local buf = open_connected(20)
    local win = browser.info().window
    vim.api.nvim_set_current_win(win)

    -- gg lands on the first tree row, never on the pinned chrome
    vim.cmd("normal! gg")
    assert.equals(tree.HEADER_LINES + 1, vim.api.nvim_win_get_cursor(win)[1],
      "gg must bottom out on the first tree row")

    -- k at the first tree row stays there (row 2 is under the overlay)
    vim.api.nvim_win_set_cursor(win, { tree.HEADER_LINES + 1, 0 })
    vim.cmd("normal! k")
    assert.equals(tree.HEADER_LINES + 1, vim.api.nvim_win_get_cursor(win)[1],
      "k must not climb onto the pinned rows")

    -- editing sits the caret on the bar (overlay hidden); commit walks it
    -- back to the tree so it is never stranded under the re-shown overlay
    browser._test.search_enter()
    assert.equals(1, vim.api.nvim_win_get_cursor(win)[1], "editing needs the bar row")
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "key:001" })
    browser._test.search_commit()
    assert.equals(tree.HEADER_LINES + 1, vim.api.nvim_win_get_cursor(win)[1],
      "commit must move the caret off the pinned bar row")
  end)

  it("drops the overlay when the browser window closes", function()
    open_connected(5)
    assert.is_truthy(header_bar.float_win())

    browser.close()
    assert.is_nil(header_bar.float_win())
    assert.is_nil(header_bar._test.state().buf, "mirror buffer must be wiped")

    -- the :q path (window closed without the keymap): WinClosed drops the
    -- float the same way
    stub_keys(5)
    browser.open()
    assert.is_true(vim.wait(2000, function()
      return header_bar.float_win() ~= nil
    end, 5), "overlay was not recreated on reopen")
    local fwin = header_bar.float_win()
    vim.api.nvim_win_close(browser.info().window, true)
    assert.is_nil(header_bar.float_win(),
      "overlay outlived its anchor window (:q path)")
    assert.falsy(fwin and vim.api.nvim_win_is_valid(fwin))
  end)
end)
