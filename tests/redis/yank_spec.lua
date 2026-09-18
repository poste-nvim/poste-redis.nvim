--- yank spec — the result-panel yank actions: register targets, grid/page
--- arithmetic and the text-tab fallback.
local yank = require("poste-redis.buffer.yank")

local function make_table_tab(overrides)
  local base = {
    kind = "table",
    page = 1,
    page_size = 2,
    cursor = { row = 1, col = 2 },
    grid = {
      columns = { "#", "value" },
      to_copy = function(v) return v end,
      rows = {
        { 1, "a", "extra" },
        { 2, "b", "extra" },
        { 3, "c", "extra" },
      },
    },
  }
  return vim.tbl_deep_extend("force", base, overrides or {})
end

describe("poste-redis buffer yank", function()
  describe("current", function()
    it("yanks the whole grid as TSV rows, skipping the index column", function()
      local reg = {}
      local orig = vim.fn.setreg
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.fn.setreg = function(name, text) reg[name] = text end
      yank.current(make_table_tab())
      vim.fn.setreg = orig
      assert.equals("a\textra\nb\textra\nc\textra", reg['"'])
      -- `+` too: the whole-result yank must reach the system clipboard like
      -- cell/column do
      assert.equals("a\textra\nb\textra\nc\textra", reg["+"])
    end)

    it("yanks text tabs' rendered lines", function()
      local reg = {}
      local orig = vim.fn.setreg
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.fn.setreg = function(name, text) reg[name] = text end
      yank.current({ kind = "text", lines = { "one", "two" } })
      vim.fn.setreg = orig
      assert.equals("one\ntwo", reg['"'])
      assert.equals("one\ntwo", reg["+"])
    end)
  end)

  describe("cell", function()
    it("yanks the focused cell into both registers", function()
      local reg = {}
      local orig = vim.fn.setreg
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.fn.setreg = function(name, text) reg[name] = text end
      yank.cell(make_table_tab({ cursor = { row = 2, col = 2 } }))
      vim.fn.setreg = orig
      assert.equals("b", reg['"'])
      assert.equals("b", reg["+"])
    end)

    it("maps page-local cursor rows through the page size", function()
      local reg = {}
      local orig = vim.fn.setreg
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.fn.setreg = function(name, text) reg[name] = text end
      yank.cell(make_table_tab({ page = 2, cursor = { row = 1, col = 2 } }))
      vim.fn.setreg = orig
      assert.equals("c", reg['"'])
    end)

    it("falls back to current on text tabs", function()
      local reg = {}
      local orig = vim.fn.setreg
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.fn.setreg = function(name, text) reg[name] = text end
      yank.cell({ kind = "text", lines = { "raw" } })
      vim.fn.setreg = orig
      assert.equals("raw", reg['"'])
    end)
  end)

  describe("column", function()
    it("yanks the cursor column, one value per line", function()
      local reg = {}
      local orig = vim.fn.setreg
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.fn.setreg = function(name, text) reg[name] = text end
      yank.column(make_table_tab({ cursor = { row = 1, col = 2 } }))
      vim.fn.setreg = orig
      assert.equals("a\nb\nc", reg['"'])
      assert.equals("a\nb\nc", reg["+"])
    end)
  end)
end)
