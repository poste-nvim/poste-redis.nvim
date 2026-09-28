--- Result-panel column sorting: comparison semantics, stable permutation,
--- toggle cycling, and the header icon decoration. buffer/sort.lua had no
--- spec — its toggle is the only stateful piece of the result panel that
--- re-orders rows, and compare() decides where every redis string lands.
local sort = require("poste-redis.buffer.sort")

describe("poste-redis sort.compare", function()
  it("orders numeric-looking strings numerically (redis replies are strings)", function()
    assert.equals(-1, sort.compare("9", "10"))
    assert.equals(1, sort.compare("10", "9"))
    assert.equals(0, sort.compare("99", "99"))
    assert.equals(-1, sort.compare("99.5", "100"))
  end)

  it("compares non-numeric values as strings", function()
    assert.equals(-1, sort.compare("apple", "banana"))
    assert.equals(1, sort.compare("b", "a"))
    assert.equals(0, sort.compare("x", "x"))
  end)

  it("mixes numeric and string values through the string path", function()
    -- tonumber("abc") fails, so the pair falls to string order
    assert.equals(-1, sort.compare("10", "abc"))
  end)

  it("keeps nil cells comparable instead of raising", function()
    -- a short row (fewer cells than the sorted column) must not crash
    assert.equals(0, sort.compare(nil, nil))
    assert.equals(-1, sort.compare(nil, "a"))
  end)
end)

describe("poste-redis sort.apply", function()
  local function rows(...)
    return { ... }
  end

  it("sorts ascending and keeps the index cell attached", function()
    local out = sort.apply(rows({ 1, "b" }, { 2, "a" }, { 3, "c" }), 2, "asc")
    assert.same({ { 2, "a" }, { 1, "b" }, { 3, "c" } }, out)
  end)

  it("sorts descending as the exact reverse order of values", function()
    local out = sort.apply(rows({ 1, "b" }, { 2, "a" }, { 3, "c" }), 2, "desc")
    assert.same({ { 3, "c" }, { 1, "b" }, { 2, "a" } }, out)
  end)

  it("keeps ties in their original relative order (stable)", function()
    -- table.sort is not stable; the original index must break ties
    local out = sort.apply(rows({ 1, "x" }, { 2, "x" }, { 3, "x" }, { 4, "x" }), 2, "asc")
    for i, r in ipairs(out) do
      assert.equals(i, r[1], "tie row " .. i .. " kept its original position")
    end
  end)

  it("treats any dir but 'asc' as descending", function()
    local out = sort.apply(rows({ 1, "a" }, { 2, "b" }), 2, "desc")
    assert.same({ { 2, "b" }, { 1, "a" } }, out)
  end)

  it("returns a new array, sharing the row tables", function()
    local r1, r2 = { 1, "a" }, { 2, "b" }
    local out = sort.apply({ r1, r2 }, 2, "desc")
    assert.equals(2, #out)
    assert.equals(r2, out[1], "the row table is shared, not copied")
    assert.equals(r1, out[2])
  end)
end)

describe("poste-redis sort.toggle", function()
  local function tab()
    return {
      kind = "table",
      page = 1,
      page_size = 10,
      cursor = { row = 1, col = 2 },
      grid = { rows = { { 1, "b" }, { 2, "a" }, { 3, "c" } }, columns = { "#", "v" } },
    }
  end

  it("cycles none → desc → asc → none", function()
    local t = tab()
    local handled, st = sort.toggle(t)
    assert.is_true(handled)
    assert.same({ col = 2, dir = "desc" }, st)
    assert.equals("3", tostring(t.grid.rows[1][1]), "desc puts the largest first")

    handled, st = sort.toggle(t)
    assert.is_true(handled)
    assert.same({ col = 2, dir = "asc" }, st)
    assert.equals("2", tostring(t.grid.rows[1][1]), "asc puts the smallest first")

    handled, st = sort.toggle(t)
    assert.is_true(handled)
    assert.is_nil(st, "the third press clears the sort")
    assert.equals("1", tostring(t.grid.rows[1][1]), "none restores the server's order")
  end)

  it("keeps the focused record under the cursor across the re-order", function()
    local t = tab()
    t.page_size = 2
    t.page = 2 -- global row 3 = index 3
    t.cursor.row = 1
    sort.toggle(t) -- desc: c(3), b(1), a(2)
    -- the focused record (index 3) now sits at global row 1 → page 1
    assert.equals(1, t.page)
    assert.equals(1, t.cursor.row)
  end)

  it("refuses text tabs, empty grids, and the index column", function()
    assert.is_false(sort.toggle(nil))
    assert.is_false(sort.toggle({ kind = "text" }))
    local t = tab()
    t.grid.rows = {}
    assert.is_false(sort.toggle(t))
    t = tab()
    t.cursor.col = 1
    assert.is_false(sort.toggle(t), "the index column is display-only chrome")
  end)

  it("starts a different column fresh at desc", function()
    local t = tab()
    sort.toggle(t) -- col 2 desc
    t.cursor.col = 3
    local handled, st = sort.toggle(t)
    assert.is_true(handled)
    assert.same({ col = 3, dir = "desc" }, st, "a new column starts at desc, not asc")
  end)
end)

describe("poste-redis sort header decoration", function()
  it("decorates only the sorted column", function()
    assert.same({ "#", "name ▼", "ttl" }, sort.decorated_columns({ "#", "name", "ttl" },
      { col = 2, dir = "desc" }))
    assert.same({ "#", "name", "ttl" }, sort.decorated_columns({ "#", "name", "ttl" }, nil))
  end)

  it("locates the icon inside its cell region of a rendered header", function()
    local header = "│ #  │ name ▼   │ ttl │"
    local range = sort.icon_range(header, { col = 2, dir = "desc" })
    assert.truthy(range)
    -- positional pair, consumed as icon_hl[1]/icon_hl[2] by header.apply_sort_hl
    assert.equals("▼", header:sub(range[1] + 1, range[2]))
  end)

  it("returns nil without a sort or on a header missing the separators", function()
    assert.is_nil(sort.icon_range("│ # │ name │", nil))
    assert.is_nil(sort.icon_range("no separators", { col = 2, dir = "desc" }))
  end)
end)
