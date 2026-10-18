--- ui spec — the g? help-float surface: the shared layout (aligned key/desc
--- columns, per-row highlight spans) and the real float rendering.
local ui = require("poste-redis.ui")
local buffer_setup = require("poste-redis.buffer_setup")

describe("poste-redis help layout", function()
  it("aligns every desc column at widest key + two-space gap", function()
    local lines = ui.help_layout({
      { key = "<CR>", desc = "open node" },
      { key = "h", desc = "collapse" },
      { key = "<leader>/", desc = "filter" },
    })
    -- "<leader>/" is the widest key (9 display cols): every desc starts at
    -- 2 + 9 + 2, keys left-padded to the shared width
    assert.equals("  <CR>       open node", lines[1])
    assert.equals("  h          collapse", lines[2])
    assert.equals("  <leader>/  filter", lines[3])
    local c = lines[1]:find("open node", 1, true)
    assert.equals(c, lines[2]:find("collapse", 1, true), "descs must share one column")
    assert.equals(c, lines[3]:find("filter", 1, true), "descs must share one column")
  end)

  it("spans the key bytes only, with the key group", function()
    local _, spans = ui.help_layout({
      { key = "<CR>", desc = "open node" },
      { key = "h", desc = "collapse" },
    })
    assert.equals(2, #spans)
    assert.same({ row = 0, col = 2, end_col = 6, group = "PosteRedisHelpKey" }, spans[1])
    assert.same({ row = 1, col = 2, end_col = 3, group = "PosteRedisHelpKey" }, spans[2])
  end)

  it("highlights headers and notes whole-line with their own groups", function()
    local lines, spans = ui.help_layout({
      { header = "source keymaps" },
      { note = "(prose note)" },
      { blank = true },
    })
    assert.equals("source keymaps", lines[1])
    assert.equals("(prose note)", lines[2])
    assert.equals("", lines[3])
    assert.same({ row = 0, col = 0, end_col = 14, group = "PosteRedisHelpHeader" }, spans[1])
    assert.same({ row = 1, col = 0, end_col = 12, group = "PosteRedisHelpNote" }, spans[2])
    assert.equals(2, #spans, "blank rows carry no span")
  end)
end)

describe("poste-redis source help rows", function()
  it("covers the documented keymaps of both panels, headers between", function()
    local rows = buffer_setup._test.help_rows(function(_, action) return "<" .. action .. ">" end)
    local headers = {}
    local blanks = 0
    local keyed = {}
    for _, r in ipairs(rows) do
      if r.header then headers[#headers + 1] = r.header end
      if r.blank then blanks = blanks + 1 end
      if r.key then keyed[#keyed + 1] = r.key end
    end
    assert.same({ "poste-redis source keymaps", "poste-redis result panel keymaps" }, headers)
    assert.equals(1, blanks, "one spacer between the two panels")
    -- every key/desc row must carry both halves — a missing desc renders an
    -- empty column and breaks the alignment story
    for _, r in ipairs(rows) do
      if r.key then assert.truthy(r.desc and r.desc ~= "") end
    end
    -- 7 source rows + 9 result rows
    assert.equals(16, #keyed)
  end)

  it("uses the real defaults for the format function", function()
    local config = require("poste-redis.config")
    local rows = buffer_setup._test.help_rows(config.format_keymap)
    -- format_keymap renders named keys in display form (<CR> → Enter)
    assert.equals("Enter", rows[2].key)
    assert.equals("run command under cursor / selection", rows[2].desc)
  end)
end)

describe("poste-redis help float rendering", function()
  after_each(function()
    pcall(vim.api.nvim_win_close, 0, true)
  end)

  it("renders the laid-out lines and applies the extmark groups", function()
    local rows = {
      { header = "keys" },
      { key = "<CR>", desc = "open" },
      { key = "h", desc = "left" },
    }
    local win, buf = ui.help_float(rows, { title = "help test" })
    assert.is_true(vim.api.nvim_win_is_valid(win))
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.equals("keys", lines[1])
    assert.equals("  <CR>  open", lines[2])
    assert.equals("  h     left", lines[3])

    local ns = vim.api.nvim_create_namespace("PosteRedisHelp")
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    assert.equals(3, #marks)
    assert.equals("PosteRedisHelpHeader", marks[1][4].hl_group)
    assert.equals("PosteRedisHelpKey", marks[2][4].hl_group)
    assert.equals("PosteRedisHelpKey", marks[3][4].hl_group)
  end)
end)
