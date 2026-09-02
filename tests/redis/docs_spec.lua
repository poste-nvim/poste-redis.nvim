--- docs spec — K-hover: command doc data (`docs.lua`) + provider (`doc.lua`)
--- + keymap wiring. Pure-data + headless-float tests (no redis transport).
local docs = require("poste-redis.docs")
local doc = require("poste-redis.doc")
local config = require("poste-redis.config")
local completion_data = require("poste-redis.completion.data")

describe("poste-redis docs data", function()
  it("looks up a command case-insensitively", function()
    assert.truthy(docs.lookup("HSET"))
    assert.truthy(docs.lookup("hset"))
    assert.equals("Hashes", docs.lookup("HSET").category)
  end)

  it("returns nil for unknown commands", function()
    assert.is_nil(docs.lookup("NOTACOMMAND"))
    assert.is_nil(docs.lookup(nil))
    assert.is_nil(docs.lookup(42))
  end)

  it("covers every command in the completion vocabulary", function()
    local missing = {}
    for _, cmd in ipairs(completion_data.COMMANDS) do
      if not docs.lookup(cmd) then missing[#missing + 1] = cmd end
    end
    assert.are.same({}, missing)
  end)

  it("every entry has syntax, desc, and at least one example", function()
    local broken = {}
    for cmd, entry in pairs(docs.DOCS) do
      if not entry.syntax or not entry.desc then
        broken[#broken + 1] = cmd .. " (missing syntax/desc)"
      end
      if not entry.example or #entry.example == 0 then
        broken[#broken + 1] = cmd .. " (no example)"
      end
    end
    assert.are.same({}, broken)
  end)
end)

describe("poste-redis doc provider", function()
  it("builds markdown syntax + example blocks", function()
    local lines = doc.build_lines("HSET", docs.lookup("HSET"))
    local text = table.concat(lines, "\n")
    assert.truthy(text:find("**Hashes**", 1, true))
    assert.truthy(text:find("```redis", 1, true))
    assert.truthy(text:find("HSET key field value", 1, true))
    assert.truthy(text:find("**Example**", 1, true))
    -- fenced blocks are opened and closed
    local open = select(2, text:gsub("```redis", ""))
    local fences = select(2, text:gsub("```", ""))
    assert.equals(2, open)
    assert.equals(2 * open, fences)
  end)

  it("resolve_command reads the current entry's command", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "RPUSH mylist 1 2" })
    vim.api.nvim_win_set_buf(0, buf)
    vim.api.nvim_win_set_cursor(0, { 1, 8 })
    assert.equals("RPUSH", doc.resolve_command(buf))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("resolve_command maps a USE entry to USE", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "USE production" })
    vim.api.nvim_win_set_buf(0, buf)
    vim.api.nvim_win_set_cursor(0, { 1, 3 })
    assert.equals("USE", doc.resolve_command(buf))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("resolve_command falls back to the word under cursor on a comment line", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# HSET user:1000", "GET k" })
    vim.api.nvim_win_set_buf(0, buf)
    vim.api.nvim_win_set_cursor(0, { 1, 4 })
    assert.equals("HSET", doc.resolve_command(buf))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("open_doc_preview re-focuses the tracked window on the same key", function()
    local _, win1 = doc.open_doc_preview({ "hello" }, { track_key = "cmd:GET" })
    assert.truthy(win1 and vim.api.nvim_win_is_valid(win1))
    local _, win2, reused = doc.open_doc_preview({ "hello" }, { track_key = "cmd:GET" })
    assert.truthy(reused)
    assert.equals(win1, win2)
    pcall(vim.api.nvim_win_close, win1, true)
  end)

  it("open_doc_preview closes a different tracked window before opening a new one", function()
    local b1 = nil
    local _, win1 = doc.open_doc_preview({ "a" }, { track_key = "cmd:GET" })
    b1 = vim.api.nvim_win_get_buf(win1)
    local _, win2, reused = doc.open_doc_preview({ "b" }, { track_key = "cmd:SET" })
    assert.is_false(reused)
    assert.truthy(win2 and vim.api.nvim_win_is_valid(win2))
    assert.is_false(vim.api.nvim_buf_is_valid(b1))
    pcall(vim.api.nvim_win_close, win2, true)
  end)
end)

describe("poste-redis doc keymap", function()
  it("binds show_doc to K by default", function()
    assert.equals("K", config.defaults.keymaps.redis_source.show_doc)
    assert.equals("K", config.get_keymap("redis_source", "show_doc", "K"))
  end)

  it("honors a show_doc override from a merged config", function()
    config.merge({ keymaps = { redis_source = { show_doc = "K" } } })
    assert.equals("K", config.get_keymap("redis_source", "show_doc"))
  end)

  it("disable via false", function()
    config.merge({ keymaps = { redis_source = { show_doc = false } } })
    assert.is_nil(config.get_keymap("redis_source", "show_doc"))
  end)
end)