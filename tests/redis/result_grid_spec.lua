--- result grid spec — poste-db-style table rendering for Set/List/Hash/Zset:
--- layout widths, pagination, cell navigation, search, yank, preview.
local format = require("poste-redis.format")
local grid = require("poste-redis.result.grid")
local icons = require("poste-redis.icons")
local header = require("poste-redis.result.header")
local buffer = require("poste-redis.buffer")

local function grid_for(value)
  return format.format_result({ seq = 1, command = "X k", status = "", latency_ms = 1, value = value })
end

describe("poste-redis result grid", function()
  after_each(function()
    buffer.close()
    header.close()
    pcall(vim.api.nvim_win_close, 0, true)
  end)

  describe("build_layout", function()
    it("computes widths from header + cells, keeps the index column narrow", function()
      local out = grid_for({ type = "hash", entries = { { "name", "Alice" }, { "email", "bob@example.com" } }, len = 2 })
      local layout = grid.build_layout(out.grid)
      assert.equals(3, layout.col_count)
      -- index col fits its icon+type header, value col fits the longest value
      assert.truthy(layout.widths[1] >= 1)
      assert.truthy(layout.widths[3] >= #"bob@example.com")
      -- the index column is left-aligned (only extra right_align columns differ)
      assert.same({}, layout.right)
    end)

    it("right-aligns the zset score column", function()
      local out = grid_for({ type = "zset", value = { { member = "a", score = 99 } }, len = 1 })
      local layout = grid.build_layout(out.grid)
      assert.same({ 3 }, layout.right)
    end)

    it("caps content columns at the max width", function()
      local long = string.rep("x", 500)
      local out = grid_for({ type = "list", value = { long }, len = 1 })
      local layout = grid.build_layout(out.grid)
      assert.equals(80, layout.widths[2])
    end)

    it("handles CJK widths without splitting", function()
      local out = grid_for({ type = "list", value = { "日本語", "abc" }, len = 2 })
      local layout = grid.build_layout(out.grid)
      assert.truthy(layout.widths[2] >= 6)
    end)
  end)

  describe("render_page", function()
    it("renders the poste-db style header + data rows", function()
      local out = grid_for({ type = "list", value = { "job-1", "job-2" }, len = 2 })
      local layout = grid.build_layout(out.grid)
      local lines, meta = grid.render_page(out.grid, layout, 1, 50)
      local label = icons.type_label("list")
      assert.equals("  │ " .. label .. " │ value │", lines[1])
      local pad = string.rep(" ", vim.fn.strdisplaywidth(label) - 1)
      assert.equals("  │ 1" .. pad .. " │ job-1 │", lines[2])
      assert.equals("  │ 2" .. pad .. " │ job-2 │", lines[3])
      assert.equals(1, meta.header_line)
      assert.equals(2, meta.data_start_line)
      assert.equals(2, meta.row_count)
      assert.equals(1, meta.num_pages)
    end)

    it("paginates and clamps the page number", function()
      local rows = {}
      for i = 1, 120 do rows[i] = "item-" .. i end
      local out = grid_for({ type = "list", value = rows, len = 120 })
      local layout = grid.build_layout(out.grid)
      local _, meta = grid.render_page(out.grid, layout, 1, 50)
      assert.equals(3, meta.num_pages)
      assert.equals(50, meta.row_count)
      local _, last = grid.render_page(out.grid, layout, 9, 50)
      assert.equals(3, last.page)
      assert.equals(20, last.row_count)
    end)

    it("appends a footer line below the data", function()
      local out = grid_for({ type = "list", value = { "a" }, len = 1000, truncated = true })
      local layout = grid.build_layout(out.grid)
      local lines, meta = grid.render_page(out.grid, layout, 1, 50, "  (1000 total, server capped)")
      assert.equals("  (1000 total, server capped)", lines[#lines])
      assert.equals(2, meta.data_start_line)
      assert.equals(1, meta.row_count)
    end)

    it("right-aligns # and score cells", function()
      local out = grid_for({ type = "zset", value = { { member = "alice", score = 99 } }, len = 1 })
      local layout = grid.build_layout(out.grid)
      local lines = grid.render_page(out.grid, layout, 1, 50)
      -- score "99" sits flush right against its trailing `│`
      assert.match(" 99 │$", lines[2])
    end)
  end)

  describe("cell navigation on the panel", function()
    local function open_grid(entries)
      buffer.render({ {
        seq = 1, command = "HGETALL k", status = "", latency_ms = 1,
        value = { type = "hash", entries = entries, len = #entries },
      } }, { render = true })
    end

    it("refresh re-runs the tab's command and replaces the grid", function()
      -- stub the session transport: first HGETALL returns v1, refresh returns v2
      local session_conn = require("poste-redis.session_conn")
      local connections = require("poste-redis.connections")
      local orig_execute = session_conn.execute
      local orig_resolve = connections.resolve_redis_url
      connections.resolve_redis_url = function(name)
        assert.equals("stub", name)
        return "redis://stub:6379/0", nil
      end
      -- the initial tab is built directly; every execute call is a refresh
      session_conn.execute = function(conn_url, cmd, cbs)
        if cbs and cbs.on_response then
          cbs.on_response({ seq = 1, command = table.concat(cmd, " "), status = "",
            latency_ms = 1, value = { type = "hash", entries = { { "Bob", "31" } }, len = 1 } })
        end
        return "dispatched"
      end
      buffer.render({ {
        seq = 1, command = "HGETALL k", status = "", latency_ms = 1,
        value = { type = "hash", entries = { { "name", "Alice" } }, len = 1 },
      } }, { render = true, connection = "stub" })
      local tab = buffer.active_tab()
      assert.equals("Alice", tab.grid.rows[1][3])
      buffer.refresh()
      local tab2 = buffer.active_tab()
      -- refreshed entries: { "Bob", "31" } -> field col = "Bob", value col = "31"
      assert.equals("Bob", tab2.grid.rows[1][2])
      assert.equals("31", tab2.grid.rows[1][3])
      assert.equals("HGETALL k", tab2.meta.command)
      -- the fresh result owns the time-varying meta: identity stamps
      -- (connection/db) survive, value/status/latency do NOT stay stale
      assert.equals("stub", tab2.meta.connection)
      assert.same({ type = "hash", entries = { { "Bob", "31" } }, len = 1 }, tab2.meta.value)
      session_conn.execute = orig_execute
      connections.resolve_redis_url = orig_resolve
    end)

    it("refresh(tab) replaces THAT tab's slot and leaves the active tab alone", function()
      -- Regression: refresh always took state.tabs[state.active], so a write
      -- whose response landed after the user switched tabs re-ran an
      -- unrelated command and overwrote the tab on screen.
      local session_conn = require("poste-redis.session_conn")
      local connections = require("poste-redis.connections")
      local orig_execute, orig_resolve = session_conn.execute, connections.resolve_redis_url
      local ran = {}
      connections.resolve_redis_url = function() return "redis://stub:6379/0", nil end
      session_conn.execute = function(_url, cmd, cbs)
        -- the winbar TTL probe runs on every tab switch; it is not a refresh
        if cmd[1] ~= "TTL" then ran[#ran + 1] = table.concat(cmd, " ") end
        if cbs and cbs.on_response then
          cbs.on_response({ seq = 1, command = table.concat(cmd, " "), status = "",
            latency_ms = 1, value = { type = "hash", entries = { { "fresh", "1" } }, len = 1 } })
        end
        return "dispatched"
      end
      buffer.render({
        { seq = 1, command = "HGETALL key-a", status = "", latency_ms = 1,
          value = { type = "hash", entries = { { "name", "Alice" } }, len = 1 } },
        { seq = 2, command = "HGETALL key-b", status = "", latency_ms = 1,
          value = { type = "hash", entries = { { "other", "Bob" } }, len = 1 } },
      }, { render = true, connection = "stub" })
      local tabs = buffer._tabs()
      local first, second = tabs[1], tabs[2]
      buffer.next_tab()
      assert.equals(second, buffer.active_tab())

      buffer.refresh(first)

      assert.same({ "HGETALL key-a" }, ran, "only the written tab's command re-runs")
      local replaced = buffer._tabs()[1]
      assert.are_not.equal(first, replaced)
      assert.equals("fresh", replaced.grid.rows[1][2])
      -- the active tab is untouched, and so is the panel: refreshing a
      -- background tab must not repaint the screen with it
      assert.equals(second, buffer._tabs()[2])
      local shown = table.concat(vim.api.nvim_buf_get_lines(buffer.buf(), 0, -1, false), "\n")
      assert.truthy(shown:find("Bob", 1, true))
      assert.is_nil(shown:find("fresh", 1, true))
      -- `K` previews state.last_value, which only the tab on screen owns: a
      -- background refresh must not hijack it
      local preview_mod = require("poste-redis.buffer.preview")
      local orig_raw, previewed = preview_mod.raw, nil
      preview_mod.raw = function(v) previewed = v end
      buffer.preview_raw()
      preview_mod.raw = orig_raw
      assert.same({ type = "hash", entries = { { "other", "Bob" } }, len = 1 }, previewed)
      session_conn.execute = orig_execute
      connections.resolve_redis_url = orig_resolve
    end)

    it("a refresh response for a tab that is gone is dropped", function()
      local session_conn = require("poste-redis.session_conn")
      local connections = require("poste-redis.connections")
      local orig_execute, orig_resolve = session_conn.execute, connections.resolve_redis_url
      connections.resolve_redis_url = function() return "redis://stub:6379/0", nil end
      local pending = nil
      session_conn.execute = function(_url, _cmd, cbs)
        pending = cbs
        return "dispatched"
      end
      buffer.render({ {
        seq = 1, command = "HGETALL k", status = "", latency_ms = 1,
        value = { type = "hash", entries = { { "name", "Alice" } }, len = 1 },
      } }, { render = true, connection = "stub" })
      local tab = buffer.active_tab()
      buffer.refresh(tab)
      assert.truthy(pending)
      buffer.clear()  -- the tabs are gone before the answer lands

      local ok, err = pcall(function()
        pending.on_response({ seq = 1, command = "HGETALL k", status = "", latency_ms = 1,
          value = { type = "hash", entries = { { "fresh", "1" } }, len = 1 } })
      end)
      session_conn.execute = orig_execute
      connections.resolve_redis_url = orig_resolve
      assert.is_true(ok, tostring(err))
      assert.equals(0, #buffer._tabs(), "a dead tab must not be resurrected")
    end)

    it("colors cells: index gray, numbers Number, text String", function()
      open_grid({ { "name", "Alice" }, { "age", "30" } })
      local b = buffer.buf()
      local ns = vim.api.nvim_create_namespace("poste_redis_value")
      local marks = vim.api.nvim_buf_get_extmarks(b, ns, 0, -1, { details = true })
      assert.equals(6, #marks)  -- 2 rows x (index + field + value)
      local by_hl = {}
      for _, m in ipairs(marks) do
        by_hl[m[4].hl_group] = (by_hl[m[4].hl_group] or 0) + 1
      end
      -- index column gray; "30" numeric -> Number; "Alice"/"name"/"age" -> String
      assert.equals(2, by_hl["PosteRedisResultRowNum"])
      assert.equals(1, by_hl["PosteRedisResultNumber"])
      assert.equals(3, by_hl["PosteRedisResultString"])
    end)

    it("renders a grid tab into the panel buffer (header floats, blank line 1)", function()
      open_grid({ { "a", "1" }, { "b", "2" } })
      assert.is_true(buffer.is_open())
      local tab = buffer.active_tab()
      assert.equals("table", tab.kind)
      local body = vim.api.nvim_buf_get_lines(buffer.buf(), 0, -1, false)
      -- line 1 is the blank that the floating header overlays; data starts at 2
      assert.equals("", body[1])
      assert.equals(2, tab.pmeta.data_start_line)
      local joined = table.concat(body, "\n")
      assert.truthy(joined:find("a"))
      assert.truthy(joined:find("2"))
      assert.is_nil(joined:find("field", 1, true))  -- header is not in the body
    end)

    it("the floating header follows the panel's width when a split narrows it", function()
      open_grid({ { "a", "1" }, { "b", "2" } })
      local fw = header._test.float_win()
      assert.is_truthy(fw, "header float did not open")
      local wide = vim.api.nvim_win_get_config(fw).width

      -- stand-in for the browser column: a right split narrows the panel
      -- between grid renders; the float must not keep the stale (wider)
      -- width — it would overhang into the neighbor and paint over a
      -- browser row (floats layer above normal windows at any z-index)
      vim.cmd("botright 35vsplit")
      vim.api.nvim_exec_autocmds("WinResized", {})
      local panel_win = buffer.win()
      local cfg = vim.api.nvim_win_get_config(fw)
      assert.equals(vim.api.nvim_win_get_width(panel_win), cfg.width,
        "header float must track the narrowed panel's width")
      assert.is_true(cfg.width < wide, "float must have narrowed with the panel")
    end)

    it("moves the cell cursor with move_cell and clamps (index column skipped)", function()
      open_grid({ { "a", "1" }, { "b", "2" } })
      local tab = buffer.active_tab()
      -- the row-index column (1) is display-only: the cursor starts on the
      -- first content column and h never enters the index
      assert.same({ row = 1, col = 2 }, tab.cursor)
      buffer.move_cell(0, -1)
      assert.same({ row = 1, col = 2 }, tab.cursor)
      buffer.move_cell(0, 1)
      assert.same({ row = 1, col = 3 }, tab.cursor)
      buffer.move_cell(1, 1)
      assert.same({ row = 2, col = 3 }, tab.cursor)  -- clamped to col 3 (hash: #, field, value)
      buffer.move_cell(-1, -3)
      assert.same({ row = 1, col = 2 }, tab.cursor)
    end)

    it("goto_first_row / goto_last_row", function()
      open_grid({ { "a", "1" }, { "b", "2" }, { "c", "3" } })
      buffer.goto_last_row()
      assert.equals(3, buffer.active_tab().cursor.row)
      buffer.goto_first_row()
      assert.equals(1, buffer.active_tab().cursor.row)
    end)

    it("yank_cell copies the value, not the row index", function()
      open_grid({ { "a", "1" }, { "b", "2" } })
      -- the cursor cannot sit on the index column: it starts on the field
      -- column and yank gives the field value
      buffer.yank_cell()
      assert.equals("a", vim.fn.getreg('"'))
      -- move to the value column: yank gives the value
      buffer.move_cell(0, 1)
      buffer.yank_cell()
      assert.equals("1", vim.fn.getreg('"'))
    end)

    it("yank_column copies the whole column, one value per line", function()
      open_grid({ { "a", "1" }, { "b", "2" } })
      buffer.move_cell(0, 2)
      buffer.yank_column()
      assert.equals("1\n2", vim.fn.getreg('"'))
    end)
  describe("column sort on the panel", function()
    local sort = require("poste-redis.buffer.sort")

    it("compare orders numeric strings numerically, text as strings", function()
      assert.equals(-1, sort.compare("81", "99"))
      assert.equals(1, sort.compare(99, 87))
      assert.equals(0, sort.compare("x", "x"))
      assert.equals(-1, sort.compare("81", "alice"))  -- mixed: string compare
    end)

    it("s toggles none → desc → asc → none on the cursor column", function()
      open_grid({ { "bob", "87" }, { "alice", "99" }, { "jim", "81" } })
      local tab = buffer.active_tab()
      buffer.move_cell(0, 1)  -- the value column
      assert.is_nil(tab.sort)

      buffer.sort_column()  -- desc: numeric on the value cell
      assert.same({ col = 3, dir = "desc" }, tab.sort)
      local names = {}
      for _, r in ipairs(tab.grid.rows) do names[#names + 1] = r[2] end
      assert.same({ "alice", "bob", "jim" }, names)

      buffer.sort_column()  -- asc
      assert.same({ col = 3, dir = "asc" }, tab.sort)
      names = {}
      for _, r in ipairs(tab.grid.rows) do names[#names + 1] = r[2] end
      assert.same({ "jim", "bob", "alice" }, names)

      buffer.sort_column()  -- none: the server's original order
      assert.is_nil(tab.sort)
      names = {}
      for _, r in ipairs(tab.grid.rows) do names[#names + 1] = r[2] end
      assert.same({ "bob", "alice", "jim" }, names)
    end)

    it("the cursor follows the focused record across the re-order", function()
      open_grid({ { "bob", "87" }, { "alice", "99" }, { "jim", "81" } })
      local tab = buffer.active_tab()
      buffer.move_cell(0, 1)   -- value column
      buffer.move_cell(1, 0)   -- row 2: alice
      buffer.sort_column()     -- desc: alice's row moves to the top
      assert.equals(1, tab.cursor.row)
      assert.equals("alice", tab.grid.rows[tab.cursor.row][2])
    end)

    it("the sorted header carries the icon right of the column name", function()
      open_grid({ { "bob", "87" }, { "alice", "99" } })
      local tab = buffer.active_tab()
      buffer.move_cell(0, 1)  -- value column
      buffer.sort_column()
      local icon = sort.icon(tab.sort.dir)
      assert.truthy(tab.header_padded:find(icon, 1, true) ~= nil,
        "sort icon missing from the header line")
      local hl = tab.sort_icon_hl
      assert.equals(icon, tab.header_padded:sub(hl[1] + 1, hl[2]))
      -- the sorted column widened to make room for the icon
      assert.equals("value " .. icon, tab.layout.columns[3])
      -- clearing the sort drops the icon again
      buffer.sort_column()
      buffer.sort_column()
      assert.is_nil(tab.sort_icon_hl)
      assert.equals("value", tab.layout.columns[3])
    end)

    it("the sort icon highlight survives header right-padding (wide data cells)", function()
      -- a data cell wider than "value ▼" leaves pad between the icon and the
      -- cell's trailing space; counting back from the separator highlighted
      -- that padding instead of the icon bytes
      open_grid({ { "bob", "a-very-long-value-wider-than-header" }, { "alice", "99" } })
      local tab = buffer.active_tab()
      buffer.move_cell(0, 1)  -- value column
      buffer.sort_column()
      local icon = sort.icon(tab.sort.dir)
      local hl = tab.sort_icon_hl
      assert.equals(icon, tab.header_padded:sub(hl[1] + 1, hl[2]),
        "icon range must land on the icon, not on the cell's padding")
    end)

    it("s on the index column does nothing", function()
      open_grid({ { "a", "1" }, { "b", "2" } })
      local tab = buffer.active_tab()
      tab.cursor.col = 1
      buffer.sort_column()
      assert.is_nil(tab.sort)
      assert.equals("a", tab.grid.rows[1][2])  -- order untouched
    end)

    it("re-rendering syncs the physical caret to the focus cell", function()
      open_grid({ { "a", "1" }, { "b", "2" }, { "c", "3" } })
      local tab = buffer.active_tab()
      local win = buffer.win()
      local function caret()
        return vim.api.nvim_win_get_cursor(win)[1]
      end
      -- fresh render parks the caret on the focus cell (data row 1)
      assert.equals(tab.pmeta.data_start_line, caret())
      -- user moves to data row 2: focus and caret move together
      buffer.move_cell(1, 0)
      assert.equals(tab.pmeta.data_start_line + 1, caret())
      -- a NEW statement replaces the tabs: focus resets to row 1 and the
      -- caret must follow (it used to stay on the old line, so pressing k
      -- at the top felt dead while the focus was already there)
      open_grid({ { "x", "1" }, { "y", "2" } })
      tab = buffer.active_tab()
      assert.equals(1, tab.cursor.row)
      assert.equals(tab.pmeta.data_start_line, caret(),
        "caret must track the focus cell after a re-render")
    end)

    it("render while another window is current does not scroll that window", function()
      open_grid({ { "a", "1" } })
      local src = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(src, 0, -1, false, { string.rep("x", 200) })
      vim.api.nvim_set_current_buf(src)
      vim.api.nvim_set_option_value("wrap", false, { win = 0 })
      -- scroll the source window programmatically (zh is unreliable headless)
      local sv = vim.api.nvim_win_call(0, function() return vim.fn.winsaveview() end)
      sv.leftcol = 30
      vim.api.nvim_win_call(0, function() vim.fn.winrestview(sv) end)
      local leftcol = vim.fn.winsaveview().leftcol
      assert.is_true(leftcol > 0, "test setup: source window must be scrolled")
      -- re-render positions the panel caret while the source window is
      -- current; the source window's horizontal view must stay untouched
      require("poste-redis.buffer.view").render_active()
      assert.equals(leftcol, vim.fn.winsaveview().leftcol,
        "the source window's horizontal view must be untouched")
      pcall(vim.api.nvim_buf_delete, src, { force = true })
    end)
  end)

  describe("pagination on the panel", function()
    it("next_page/prev_page/goto_first/last flip pages and clamp cursor", function()
      local rows = {}
      for i = 1, 120 do rows[#rows + 1] = "v" .. i end
      buffer.render({ {
        seq = 1, command = "LRANGE k 0 -1", status = "", latency_ms = 1,
        value = { type = "list", value = rows, len = 120 },
      } }, { render = true })
      local tab = buffer.active_tab()
      assert.equals(3, tab.num_pages)
      assert.equals(1, tab.page)
      buffer.next_page()
      assert.equals(2, tab.page)
      -- body now starts at row 51
      local joined = table.concat(vim.api.nvim_buf_get_lines(buffer.buf(), 0, -1, false), "\n")
      assert.truthy(joined:find("v51"))
      buffer.goto_last_page()
      assert.equals(3, tab.page)
      buffer.goto_first_page()
      assert.equals(1, tab.page)
    end)
  end)

  describe("search", function()
    it("compute_matches finds case-insensitive substring matches, skipping #", function()
      local out = grid_for({ type = "list", value = { "Alice", "bob", "alice2" }, len = 3 })
      local matches = grid.compute_matches(out.grid, "alice")
      assert.equals(2, #matches)
      assert.same({ row = 1, col = 2 }, matches[1])
      assert.same({ row = 3, col = 2 }, matches[2])
    end)

    it("cell_match_range maps a match to absolute byte columns", function()
      local out = grid_for({ type = "hash", entries = { { "name", "Alice Smith" } }, len = 1 })
      local layout = grid.build_layout(out.grid)
      local lines, meta = grid.render_page(out.grid, layout, 1, 50)
      local line = lines[2]
      local range = meta.col_starts[1][3]  -- value column of row 1
      local s, e = grid.cell_match_range(line, range, "ice")
      assert.truthy(s ~= nil)
      assert.equals("ice", line:sub(s + 1, e))
    end)

    it("show_search via stubbed ui.input computes and jumps to the first match", function()
      local rows = {}
      for i = 1, 3 do rows[i] = { "k" .. i, "v" .. i } end
      buffer.render({ {
        seq = 1, command = "HGETALL k", status = "", latency_ms = 1,
        value = { type = "hash", entries = rows, len = 3 },
      } }, { render = true })
      local orig = vim.ui.input
      vim.ui.input = function(_, cb) cb("k2") end
      buffer.show_search()
      vim.ui.input = orig
      local tab = buffer.active_tab()
      assert.equals("k2", tab.search_text)
      assert.equals(1, #tab.search_matches)
      assert.same({ row = 2, col = 2 }, tab.search_matches[1])
      assert.equals(2, tab.cursor.row)
      assert.equals(2, tab.cursor.col)
    end)
  end)

  describe("preview", function()
    it("preview_cell opens a float for the current cell", function()
      local rows = { { "a", "1" } }
      buffer.render({ {
        seq = 1, command = "HGETALL k", status = "", latency_ms = 1,
        value = { type = "hash", entries = rows, len = 1 },
      } }, { render = true })
      buffer.move_cell(0, 2)
      buffer.preview_cell()
      local floats = 0
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_config(w).relative ~= "" then floats = floats + 1 end
      end
      assert.truthy(floats >= 1)
    end)
  end)

  describe("header float", function()
    it("slices a header line to the viewport without breaking alignment", function()
      local idx = header._test.build_index("  │ # │ 名字 │ value │")
      local text = header._test.slice_to_win(0, 10, "  │ # │ 名字 │ value │", idx)
      assert.truthy(vim.fn.strdisplaywidth(text) <= 10)
      -- the sliced text is still valid UTF-8 (strdisplaywidth would not error)
      assert.truthy(vim.fn.strdisplaywidth(text) >= 0)
    end)
  end)
end)

describe("poste-redis grid editing", function()
  local grid_edit = require("poste-redis.browser.grid_edit")
  local session_conn = require("poste-redis.session_conn")
  local connections = require("poste-redis.connections")

  local sent_cmds = {}
  local refreshes = 0
  local ttl_reply = 60  -- what the stub's TTL probe answers
  local lindex_reply = nil  -- what the stub's LINDEX probe answers (nil = skip)
  local hexists_reply = 0  -- HEXISTS probe answer: 1 = the field is taken
  local zscore_reply = nil  -- ZSCORE probe answer: non-nil = the member exists

  local function open_key_tab_conn(value)
    buffer.render({ {
      seq = 1, command = "GET user:1", status = "", latency_ms = 1,
      value = value, connection = "stubconn",
    }, }, { render = true, connection = "stubconn" })
    local t = buffer.active_tab()
    t.meta.key = "user:1"
    t.meta.db = 0
    -- show_panel's wiring re-registers M.refresh; re-assert the counter on top
    -- (counting only — calling buffer.refresh here would re-dispatch through
    -- the recording stub and pollute sent_cmds)
    grid_edit.set_refresh(function()
      refreshes = refreshes + 1
    end)
  end

  before_each(function()
    sent_cmds = {}
    refreshes = 0
    ttl_reply = 60
    lindex_reply = nil
    hexists_reply = 0
    zscore_reply = nil
    -- counting refresh that still re-runs the tab command (M.refresh)
    grid_edit.set_refresh(function()
      refreshes = refreshes + 1
    end)
    session_conn.execute = function(url, cmd, cbs)
      -- the winbar TTL probe: answered, never recorded as an edit command
      if cmd[1] == "TTL" then
        if cbs and cbs.on_response then
          cbs.on_response({ value = { type = "number", value = ttl_reply } })
        end
        return "dispatched"
      end
      if cmd[1] == "LINDEX" then
        if cbs and cbs.on_response then
          cbs.on_response({ value = { type = "string", value = lindex_reply } })
        end
        return "dispatched"
      end
      -- the name-free probes read the server, they are not edits either
      if cmd[1] == "HEXISTS" then
        if cbs and cbs.on_response then
          cbs.on_response({ value = { type = "integer", value = hexists_reply } })
        end
        return "dispatched"
      end
      if cmd[1] == "ZSCORE" then
        if cbs and cbs.on_response then
          cbs.on_response({ value = zscore_reply ~= nil
              and { type = "string", value = tostring(zscore_reply) }
              or { type = "nil", value = nil } })
        end
        return "dispatched"
      end
      sent_cmds[#sent_cmds + 1] = table.concat(cmd, " ")
      if cbs and cbs.on_response then
        cbs.on_response({ value = { type = "string", value = "OK" } })
      end
      return "dispatched"
    end
    connections.resolve_redis_url = function(name)
      return "redis://stub:6379/0", nil
    end
  end)

  after_each(function()
    session_conn.execute = nil
    connections.resolve_redis_url = nil
  end)

  it("string edit issues SET with KEEPTTL (a bare SET clears the TTL)", function()
    open_key_tab_conn({ type = "string", value = "hello" })
    buffer.active_tab().cursor = { row = 1, col = 2 }
    vim.ui.input = function(opts, cb) cb("world") end
    grid_edit.edit_cell(buffer.active_tab())
    assert.equals("SET user:1 world KEEPTTL", sent_cmds[1])
    assert.equals(1, refreshes)
  end)

  it("a write that lands after a tab switch refreshes ITS OWN tab", function()
    -- the panel's refresh takes the tab the write came from: the user can
    -- switch tabs while the write is in flight, and refreshing whatever is
    -- active then spends an unrelated command on someone else's tab
    local write_tab = nil
    local pending_write = nil
    session_conn.execute = function(_url, cmd, cbs)
      if cmd[1] == "TTL" then
        cbs.on_response({ value = { type = "number", value = ttl_reply } })
        return "dispatched"
      end
      pending_write = cbs
      return "dispatched"
    end
    buffer.render({
      { seq = 1, command = "GET user:1", status = "", latency_ms = 1,
        value = { type = "string", value = "hello" }, connection = "stubconn" },
      { seq = 2, command = "GET other:2", status = "", latency_ms = 1,
        value = { type = "string", value = "world" }, connection = "stubconn" },
    }, { render = true, connection = "stubconn" })
    local tabs = buffer._tabs()
    -- render's show_panel re-wired the refresh back to M.refresh: re-assert the
    -- capture on top, and count only (calling through would hit the stub again)
    grid_edit.set_refresh(function(t)
      refreshes = refreshes + 1
      write_tab = t
    end)
    tabs[1].cursor = { row = 1, col = 2 }
    vim.ui.input = function(_, cb) cb("edited") end
    grid_edit.edit_cell(tabs[1])
    assert.equals(0, refreshes, "no refresh before the server answers")

    buffer.next_tab()
    assert.equals(tabs[2], buffer.active_tab())
    pending_write.on_response({ value = { type = "string", value = "OK" } })

    assert.equals(1, refreshes)
    assert.equals(tabs[1], write_tab, "the written tab is the refreshed tab")
  end)

  it("string add_row issues SET with KEEPTTL too", function()
    open_key_tab_conn({ type = "string", value = "hello" })
    vim.ui.input = function(opts, cb) cb("next") end
    grid_edit.add_row(buffer.active_tab())
    assert.equals("SET user:1 next KEEPTTL", sent_cmds[1])
  end)

  it("writes land in the command history", function()
    local history = require("poste-redis.history")
    history.clear()
    open_key_tab_conn({ type = "string", value = "hello" })
    buffer.active_tab().cursor = { row = 1, col = 2 }
    vim.ui.input = function(opts, cb) cb("world") end
    grid_edit.edit_cell(buffer.active_tab())
    local items = history.list()
    assert.equals(1, #items, "exactly one entry per write (TTL probes excluded)")
    assert.equals("SET user:1 world KEEPTTL", items[1].command)
    assert.equals("write", items[1].kind)
    assert.equals("stubconn", items[1].connection)
    history.clear()
  end)

  it("hash edit on the value column issues HSET", function()
    open_key_tab_conn({ type = "hash", entries = { { "name", "Alice" } }, len = 1 })
    local t = buffer.active_tab()
    t.cursor = { row = 1, col = 3 }  -- value cell
    vim.ui.input = function(opts, cb) cb("Bob") end
    grid_edit.edit_cell(t)
    assert.equals("HSET user:1 name Bob", sent_cmds[#sent_cmds])
  end)

  --- Capture vim.notify for the duration of one action.
  local function capture_notify(fn)
    local msgs = {}
    local orig = vim.notify
    vim.notify = function(msg, _level, _opts) msgs[#msgs + 1] = tostring(msg) end
    local ok, err = pcall(fn)
    vim.notify = orig
    assert.is_true(ok, tostring(err))
    return msgs
  end

  local function any_contains(msgs, needle)
    for _, m in ipairs(msgs) do
      if m:find(needle, 1, true) then return true end
    end
    return false
  end

  it("renaming a hash field onto an existing field writes nothing", function()
    -- HSET onto a taken name would replace that field's value and HDEL would
    -- then remove the original: one edit, two entries gone
    open_key_tab_conn({ type = "hash", entries = { { "name", "Alice" }, { "nick", "Al" } }, len = 2 })
    local t = buffer.active_tab()
    t.cursor = { row = 1, col = 2 }
    hexists_reply = 1
    vim.ui.input = function(_, cb) cb("nick") end
    local msgs = capture_notify(function() grid_edit.edit_cell(t) end)
    assert.same({}, sent_cmds)
    assert.is_true(any_contains(msgs, "already exists"))
    assert.equals(0, refreshes, "a refused write has nothing to refresh")
  end)

  it("renaming a hash field onto a free name probes then rewrites the pair", function()
    open_key_tab_conn({ type = "hash", entries = { { "name", "Alice" }, { "nick", "Al" } }, len = 2 })
    local t = buffer.active_tab()
    t.cursor = { row = 1, col = 2 }
    vim.ui.input = function(_, cb) cb("fullname") end
    grid_edit.edit_cell(t)
    assert.same({ "HSET user:1 fullname Alice", "HDEL user:1 name" }, sent_cmds)
  end)

  it("renaming a zset member onto an existing member writes nothing", function()
    open_key_tab_conn({ type = "zset",
      value = { { member = "alice", score = 99 }, { member = "bob", score = 1 } }, len = 2 })
    local t = buffer.active_tab()
    t.cursor = { row = 1, col = 2 }
    zscore_reply = 1
    local prompts = 0
    vim.ui.input = function(_, cb)
      prompts = prompts + 1
      cb(prompts == 1 and "bob" or "50")
    end
    local msgs = capture_notify(function() grid_edit.edit_cell(t) end)
    assert.same({}, sent_cmds)
    assert.is_true(any_contains(msgs, "already exists"))
  end)

  it("renaming a zset member onto a free name probes then moves the score", function()
    open_key_tab_conn({ type = "zset", value = { { member = "alice", score = 99 } }, len = 1 })
    local t = buffer.active_tab()
    t.cursor = { row = 1, col = 2 }
    local prompts = 0
    vim.ui.input = function(_, cb)
      prompts = prompts + 1
      cb(prompts == 1 and "bob" or "50")
    end
    grid_edit.edit_cell(t)
    assert.same({ "ZADD user:1 50 bob", "ZREM user:1 alice" }, sent_cmds)
  end)

  it("add row refuses a field or member that already exists", function()
    open_key_tab_conn({ type = "hash", entries = { { "name", "Alice" } }, len = 1 })
    local t = buffer.active_tab()
    local prompts = 0
    vim.ui.input = function(_, cb)
      prompts = prompts + 1
      cb(prompts == 1 and "name" or "value")
    end
    hexists_reply = 1
    capture_notify(function() grid_edit.add_row(t) end)
    assert.same({}, sent_cmds)
    hexists_reply = 0
    prompts = 0
    capture_notify(function() grid_edit.add_row(t) end)
    assert.same({ "HSET user:1 name value" }, sent_cmds)

    sent_cmds = {}
    open_key_tab_conn({ type = "zset", value = { { member = "alice", score = 99 } }, len = 1 })
    prompts = 0
    vim.ui.input = function(_, cb)
      prompts = prompts + 1
      cb(prompts == 1 and "alice" or "50")
    end
    zscore_reply = 99
    capture_notify(function() grid_edit.add_row(buffer.active_tab()) end)
    assert.same({}, sent_cmds)
  end)

  it("dd on a string key asks about deleting the key, not a row", function()
    open_key_tab_conn({ type = "string", value = "hello" })
    local t = buffer.active_tab()
    t.cursor = { row = 1, col = 2 }
    local asked = nil
    vim.fn.confirm = function(msg) asked = msg; return 2 end  -- answer No
    grid_edit.delete_row(t)
    assert.truthy(asked:find("whole value", 1, true), asked)
    assert.same({}, sent_cmds, "answering No must not delete anything")
  end)

  it("hash row delete issues HDEL field", function()
    open_key_tab_conn({ type = "hash", entries = { { "name", "Alice" } }, len = 1 })
    buffer.active_tab().cursor = { row = 1, col = 2 }
    vim.fn.confirm = function() return 1 end
    grid_edit.delete_row(buffer.active_tab())
    assert.equals("HDEL user:1 name", sent_cmds[#sent_cmds])
  end)

  it("list row delete uses LSET sentinel + LREM", function()
    open_key_tab_conn({ type = "list", value = { "job-1", "job-2" }, len = 2 })
    local t = buffer.active_tab()
    t.cursor = { row = 1, col = 2 }
    lindex_reply = "job-1"  -- LINDEX must confirm the rendered value first
    vim.fn.confirm = function() return 1 end
    grid_edit.delete_row(t)
    assert.is_truthy(sent_cmds[#sent_cmds - 1]:find("^LSET user:1 0 __POSTE_DELETE_ROW__$"))
    assert.equals("LREM user:1 1 __POSTE_DELETE_ROW__", sent_cmds[#sent_cmds])
  end)

  it("stale list cell refuses the write (LINDEX mismatch)", function()
    -- the grid's index is only the true list index when the result started
    -- at the list head and nothing shifted; a stale write corrupted an
    -- unrelated element
    open_key_tab_conn({ type = "list", value = { "job-1", "job-2" }, len = 2 })
    local t = buffer.active_tab()
    t.cursor = { row = 1, col = 2 }
    lindex_reply = "SOMETHING-ELSE"  -- server value drifted from the render
    vim.ui.input = function(opts, cb) cb("edited") end
    grid_edit.edit_cell(t)
    vim.wait(50, function() return false end, 5)
    for _, c in ipairs(sent_cmds) do
      assert.is_nil(c:find("^LSET"), "no LSET may run against a stale index")
    end
  end)

  it("matching LINDEX lets the list edit through", function()
    open_key_tab_conn({ type = "list", value = { "job-1", "job-2" }, len = 2 })
    local t = buffer.active_tab()
    t.cursor = { row = 1, col = 2 }
    lindex_reply = "job-1"
    vim.ui.input = function(opts, cb) cb("edited") end
    grid_edit.edit_cell(t)
    assert.is_truthy(vim.wait(200, function()
      for _, c in ipairs(sent_cmds) do
        if c:find("^LSET user:1 0 edited$") then return true end
      end
      return false
    end, 5), "LSET must run after a matching LINDEX")
  end)

  it("zset score edit issues ZADD", function()
    open_key_tab_conn({ type = "zset", value = { { member = "alice", score = 99 } }, len = 1 })
    local t = buffer.active_tab()
    t.cursor = { row = 1, col = 3 }
    vim.ui.input = function(opts, cb) cb("100") end
    grid_edit.edit_cell(t)
    assert.equals("ZADD user:1 100 alice", sent_cmds[#sent_cmds])
  end)

  it("add row on a set issues SADD", function()
    open_key_tab_conn({ type = "set", value = { "vim" }, len = 1 })
    vim.ui.input = function(opts, cb) cb("lua") end
    grid_edit.add_row(buffer.active_tab())
    assert.equals("SADD user:1 lua", sent_cmds[#sent_cmds])
  end)

  it("add row on a hash prompts field then value", function()
    open_key_tab_conn({ type = "hash", entries = { { "name", "Alice" } }, len = 1 })
    local prompts = {}
    vim.ui.input = function(opts, cb)
      prompts[#prompts + 1] = opts.prompt
      cb(#prompts == 1 and "email" or "bob@x")
    end
    grid_edit.add_row(buffer.active_tab())
    assert.equals("HSET user:1 email bob@x", sent_cmds[#sent_cmds])
  end)

  it("probes the key's TTL and shows it in the winbar as Number", function()
    open_key_tab_conn({ type = "string", value = "x" })
    local wb = vim.api.nvim_get_option_value("winbar", { win = buffer.win() })
    -- label is plain, the seconds sit inside the Number group encoding
    assert.match("ttl %%#Number#60%%%*", wb)
  end)

  it("counts the ttl down once per second", function()
    open_key_tab_conn({ type = "string", value = "x" })
    assert.is_true(vim.wait(1500, function()
      return (buffer.active_tab().ttl or 0) == 59
    end, 25), "ttl did not tick to 59")
  end)

  it("hides the ttl for persistent keys (-1)", function()
    ttl_reply = -1
    open_key_tab_conn({ type = "string", value = "x" })
    local wb = vim.api.nvim_get_option_value("winbar", { win = buffer.win() })
    assert.is_nil(wb:find("ttl", 1, true))
    ttl_reply = 60
  end)

  it("shows the tab's origin context (connection + db) in the winbar", function()
    buffer.render({ { seq = 1, command = "GET k", status = "", latency_ms = 1, db = 3,
      value = { type = "string", value = "x" } } },
      { render = true, connection = "stubconn" })
    local wb = vim.api.nvim_get_option_value("winbar", { win = buffer.win() })
    assert.match("stubconn db3", wb)
    buffer.close()
  end)

  it("shows credential-free hosts for URL connections, never credentials", function()
    buffer.render({ { seq = 1, command = "GET k", status = "", latency_ms = 1, db = 2,
      value = { type = "string", value = "x" } } },
      { render = true, connection = "redis://alice:s3cret@host:6379" })
    local wb = vim.api.nvim_get_option_value("winbar", { win = buffer.win() })
    assert.match("host:6379 db2", wb)
    assert.is_nil(wb:find("s3cret", 1, true))
    buffer.close()
  end)
end)

describe("poste-redis result winbar", function()
  local view = require("poste-redis.buffer.view")

  it("wraps the keyword in the Cmd group and the key in the green group", function()
    assert.equals(
      "%#PosteRedisResultWinbarCmd#GET%* %#PosteRedisResultWinbarKey#session:abc%*",
      view._test.format_command("GET session:abc"))
  end)

  it("keeps the typed form (case, quoting) and leaves extra args plain", function()
    assert.equals(
      '%#PosteRedisResultWinbarCmd#set%* %#PosteRedisResultWinbarKey#k%* "v 1" extra',
      view._test.format_command('set k "v 1" extra'))
  end)

  it("escapes % so the winbar encoding passes it through", function()
    assert.equals(
      "%#PosteRedisResultWinbarCmd#GET%* %#PosteRedisResultWinbarKey#100%%%*",
      view._test.format_command("GET 100%"))
  end)

  it("single-token commands render in the Cmd group", function()
    assert.equals("%#PosteRedisResultWinbarCmd#PING%*",
      view._test.format_command("PING"))
  end)
end)
end)
