--- pager spec — page flipping on table tabs. `view` is stubbed with a
--- recorder so the tests pin the flip/wrap rules without needing a real
--- 50+-row grid on screen.
local state = require("poste-redis.buffer.state")

describe("poste-redis pager", function()
  local pager, calls

  local function make_tab(num_pages, page)
    return {
      kind = "table",
      grid = { rows = {}, cols = {} },
      page = page or 1,
      num_pages = num_pages,
      page_size = 50,
      cursor = { row = 1, col = 1 },
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
    pager = require("poste-redis.buffer.pager")
  end)

  after_each(function()
    state.tabs = {}
    state.active = 1
  end)

  it("next/prev step within the page count", function()
    local tab = make_tab(3, 1)
    set_active(tab)
    pager.next()
    assert.equals(2, tab.page)
    pager.prev()
    assert.equals(1, tab.page)
  end)

  it("next wraps from the last page to the first", function()
    local tab = make_tab(3, 3)
    set_active(tab)
    pager.next()
    assert.equals(1, tab.page)
  end)

  it("prev wraps from the first page to the last", function()
    local tab = make_tab(3, 1)
    set_active(tab)
    pager.prev()
    assert.equals(3, tab.page)
  end)

  it("first/last jump to the edges", function()
    local tab = make_tab(4, 2)
    set_active(tab)
    pager.last()
    assert.equals(4, tab.page)
    pager.first()
    assert.equals(1, tab.page)
  end)

  it("every move re-renders the grid and re-places the cursor", function()
    local tab = make_tab(2, 1)
    set_active(tab)
    pager.next()
    assert.same(
      { "render_grid:2", "highlight_cell", "position_cursor", "update_winbar" },
      calls
    )
  end)

  it("a single-page or page-less tab is a no-op", function()
    local tab = make_tab(1, 1)
    set_active(tab)
    pager.next()
    pager.prev()
    pager.first()
    pager.last()
    assert.equals(1, tab.page)
    assert.equals(0, #calls)

    tab = make_tab(nil, 1)
    set_active(tab)
    pager.next()
    assert.equals(1, tab.page)
    assert.equals(0, #calls)
  end)

  it("ignores text tabs and an empty tab list", function()
    set_active({ kind = "text", lines = { "GET user:42" } })
    pager.next()
    pager.prev()
    pager.first()
    pager.last()
    assert.equals(0, #calls)

    state.tabs = {}
    state.active = 1
    pager.next()
    assert.equals(0, #calls)
  end)
end)
