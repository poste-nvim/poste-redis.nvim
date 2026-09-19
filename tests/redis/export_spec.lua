--- export spec — pure grid→file transforms (csv quoting, tsv cleaning,
--- json shape) and the export() guards.
local exp = require("poste-redis.buffer.export")

--- A zset-shaped grid: type label column + member/score.
local function grid(overrides)
  local base = {
    columns = { " zset", "member", "score" },
    rows = {
      { 1, "alice", "99" },
      { 2, "bob, jr", "42.5" },
      { 3, 'quo"ted', "7" },
    },
    total = 3,
    to_copy = function(v) return tostring(v) end,
  }
  return vim.tbl_deep_extend("force", base, overrides or {})
end

describe("poste-redis buffer export", function()
  describe("csv_field", function()
    it("quotes fields with commas, quotes or newlines", function()
      assert.equals("plain", exp.csv_field("plain"))
      assert.equals('"a,b"', exp.csv_field("a,b"))
      assert.equals('"say ""hi"""', exp.csv_field('say "hi"'))
      assert.equals('"line1\nline2"', exp.csv_field("line1\nline2"))
    end)
  end)

  describe("to_csv", function()
    it("skips the index column and quotes dirty fields", function()
      local lines = exp.to_csv(grid())
      assert.same({
        "member,score",
        "alice,99",
        '"bob, jr",42.5',
        '"quo""ted",7',
      }, lines)
    end)
  end)

  describe("to_tsv", function()
    it("tab-separates without quoting", function()
      local lines = exp.to_tsv(grid())
      assert.equals("member\tscore", lines[1])
      assert.equals("bob, jr\t42.5", lines[3])
    end)

    it("flattens tabs and newlines inside values to spaces", function()
      local lines = exp.to_tsv(grid({
        rows = { { 1, "a\tb\nc\rd", "1" } },
      }))
      assert.equals("a b c d\t1", lines[2])
    end)
  end)

  describe("to_json", function()
    it("emits an array of column-keyed objects, one per line", function()
      local lines = exp.to_json(grid({
        rows = { { 1, "alice", 99 }, { 2, "bob", 7 } },
        to_copy = function(v) return v end,
      }))
      -- [ / row / row / ] — 4 lines for 2 rows
      assert.equals(4, #lines)
      assert.equals("[", lines[1])
      assert.equals("]", lines[4])
      -- key order inside each object is vim.json's business; compare decoded
      local a = vim.json.decode((lines[2]:gsub(",$", "")))
      assert.same({ member = "alice", score = 99 }, a)
      local b = vim.json.decode((lines[3]:gsub(",$", "")))
      assert.same({ member = "bob", score = 7 }, b)
    end)

    it("commas every object line except the last", function()
      local lines = exp.to_json(grid({
        rows = { { 1, "alice", 99 }, { 2, "bob", 7 } },
        to_copy = function(v) return v end,
      }))
      assert.truthy(lines[2]:find(",$"))
      assert.falsy(lines[3]:find(",$"))
    end)
  end)

  describe("export guards", function()
    it("refuses text tabs and empty grids without touching pickers", function()
      assert.is_false(exp.export({ kind = "text", lines = { "x" } }))
      assert.is_false(exp.export({
        kind = "table",
        grid = { columns = { "t", "v" }, rows = {}, to_copy = function(v) return v end },
      }))
      assert.is_false(exp.export(nil))
    end)
  end)

  describe("export write path", function()
    it("expands `~` in the picked path before writefile", function()
      -- writefile does not expand `~`; completion suggests it as a target,
      -- so a typed ~/x.csv used to fail with a no-such-directory error
      local tab = {
        kind = "table",
        grid = grid(),
      }
      local orig_select, orig_input, orig_writefile = vim.ui.select, vim.ui.input, vim.fn.writefile
      local written_path
      vim.ui.select = function(_, _, cb) cb("csv") end
      vim.ui.input = function(_, cb) cb("~/exports/keys.csv") end
      vim.fn.writefile = function(lines, path)
        written_path = path
        return 0
      end
      local ok = exp.export(tab)
      vim.ui.select, vim.ui.input, vim.fn.writefile = orig_select, orig_input, orig_writefile
      assert.is_true(ok)
      assert.equals(vim.env.HOME .. "/exports/keys.csv", written_path)
    end)

    it("notices a truncated grid as a partial export", function()
      local tab = {
        kind = "table",
        grid = grid({ total = 500 }),
      }
      local orig_select, orig_input, orig_writefile, orig_notify = vim.ui.select, vim.ui.input, vim.fn.writefile, vim.notify
      local note
      vim.ui.select = function(_, _, cb) cb("json") end
      vim.ui.input = function(_, cb) cb("/tmp/poste-redis-test-export.json") end
      vim.fn.writefile = function() return 0 end
      vim.notify = function(msg) note = msg end
      local ok = exp.export(tab)
      vim.ui.select, vim.ui.input, vim.fn.writefile, vim.notify = orig_select, orig_input, orig_writefile, orig_notify
      assert.is_true(ok)
      assert.truthy(note:find("500", 1, true), "partial export must say the total")
    end)
  end)
end)
