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
      session_conn.execute = orig_execute
      connections.resolve_redis_url = orig_resolve
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

    it("moves the cell cursor with move_cell and clamps", function()
      open_grid({ { "a", "1" }, { "b", "2" } })
      local tab = buffer.active_tab()
      assert.same({ row = 1, col = 1 }, tab.cursor)
      buffer.move_cell(0, 1)
      assert.same({ row = 1, col = 2 }, tab.cursor)
      buffer.move_cell(1, 1)
      assert.same({ row = 2, col = 3 }, tab.cursor)  -- clamped to col 3 (hash: #, field, value)
      buffer.move_cell(-1, -3)
      assert.same({ row = 1, col = 1 }, tab.cursor)
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
      -- cursor starts on the "#" column: yanking it gives the row index
      buffer.yank_cell()
      assert.equals("1", vim.fn.getreg('"'))
      -- move to the field column: yank gives the field value
      buffer.move_cell(0, 1)
      buffer.yank_cell()
      assert.equals("a", vim.fn.getreg('"'))
    end)

    it("yank_column copies the whole column, one value per line", function()
      open_grid({ { "a", "1" }, { "b", "2" } })
      buffer.move_cell(0, 2)
      buffer.yank_column()
      assert.equals("1\n2", vim.fn.getreg('"'))
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