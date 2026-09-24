--- search spec — in-grid search: match computation through the REAL
--- `grid.compute_matches`, jumping through a stubbed `view`, and the
--- next/prev cycling. `vim.ui.input` is stubbed to drive `show` synchronously.
local state = require("poste-redis.buffer.state")

describe("poste-redis buffer search", function()
  local search, calls, orig_input, orig_notify, notes

  local function make_tab(grid, page)
    return {
      kind = "table",
      grid = grid,
      page = page or 1,
      num_pages = 3,
      page_size = 50,
      cursor = { row = 1, col = 1 },
      search_text = nil,
      search_matches = nil,
      search_idx = 0,
    }
  end

  local function set_active(tab)
    state.tabs = { tab }
    state.active = 1
  end

  before_each(function()
    calls = {}
    package.loaded["poste-redis.buffer.view"] = {
      render_grid = function(tab) calls[#calls + 1] = "render_grid:" .. tab.page end,
      highlight_cell = function() calls[#calls + 1] = "highlight_cell" end,
      position_cursor = function() calls[#calls + 1] = "position_cursor" end,
      update_winbar = function() calls[#calls + 1] = "update_winbar" end,
      apply_search_highlights = function() calls[#calls + 1] = "apply_search_highlights" end,
    }
    orig_input = vim.ui.input
    orig_notify = vim.notify
    notes = {}
    vim.ui.input = function(opts, cb) cb(opts and opts.default ~= nil and opts.default or "") end
    vim.notify = function(msg) notes[#notes + 1] = msg end
    search = require("poste-redis.buffer.search")
  end)

  after_each(function()
    vim.ui.input = orig_input
    vim.notify = orig_notify
    state.tabs = {}
    state.active = 1
  end)

  it("show computes case-insensitive matches and jumps to the first", function()
    local tab = make_tab({ rows = { { "1", "Alice", "x" }, { "2", "Bob", "ALICE" } } })
    set_active(tab)
    vim.ui.input = function(opts, cb) cb("alice") end
    search.show()
    assert.equals("alice", tab.search_text)
    assert.equals(2, #tab.search_matches)
    assert.equals(1, tab.search_idx)
    assert.same({ row = 1, col = 2 }, tab.search_matches[1])
  end)

  it("jump moves to the match's page and recomputes the in-page row", function()
    local tab = make_tab({ rows = {} }, 1)
    tab.search_matches = { { row = 61, col = 2 }, { row = 10, col = 3 } }
    set_active(tab)
    search.jump(tab, 2)
    assert.equals(2, tab.search_idx)
    assert.equals(1, tab.page) -- row 10 lives on page 1
    assert.equals(10, tab.cursor.row)
    assert.equals(3, tab.cursor.col)
    search.jump(tab, 1)
    assert.equals(2, tab.page) -- row 61 lives on page 2
    assert.equals(11, tab.cursor.row) -- 61 - 50
    assert.truthy(vim.tbl_contains(calls, "render_grid:2"))
  end)

  it("jump to a stale match index is a no-op", function()
    local tab = make_tab({ rows = {} })
    tab.search_matches = {}
    set_active(tab)
    search.jump(tab, 1)
    assert.equals(0, #calls)
  end)

  it("next/prev cycle through the matches and wrap", function()
    local tab = make_tab({ rows = {} })
    tab.search_matches = { { row = 1, col = 2 }, { row = 2, col = 2 }, { row = 3, col = 2 } }
    set_active(tab)
    search.next()
    assert.equals(1, tab.search_idx)
    search.next()
    assert.equals(2, tab.search_idx)
    search.prev()
    assert.equals(1, tab.search_idx)
    search.prev()
    -- 1 - 1 = 0 wraps to the last match
    assert.equals(3, tab.search_idx)
  end)

  it("next/prev without matches are no-ops", function()
    local tab = make_tab({ rows = { { "1", "Alice" } } })
    set_active(tab)
    search.next()
    search.prev()
    assert.equals(0, #calls)
  end)

  it("show announces an empty result set but stays quiet for an empty query", function()
    local tab = make_tab({ rows = { { "1", "Alice" } } })
    set_active(tab)
    vim.ui.input = function(opts, cb) cb("zzz-not-there") end
    search.show()
    assert.equals(1, #notes)
    assert.matches("No matches", notes[1])

    vim.ui.input = function(opts, cb) cb("") end
    search.show()
    assert.equals(1, #notes) -- no second note for the empty query
    assert.same({}, tab.search_matches)
  end)

  it("show and next ignore text tabs", function()
    set_active({ kind = "text", lines = { "GET user:42" } })
    search.show()
    search.next()
    search.prev()
    assert.equals(0, #notes)
  end)
end)
