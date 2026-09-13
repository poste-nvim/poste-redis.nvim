--- statusline spec — the context segment's highlight-group derivation:
--- get_ctx_color is evaluated on every statusline redraw and every cursor
--- move, so the underlying nvim_set_hl (which invalidates global highlighting
--- and forces a screen redraw) must fire only when the connections.toml
--- fingerprint actually changes.
local statusline = require("poste-redis.statusline")
local connections = require("poste-redis.connections")

describe("poste-redis statusline ctx color", function()
  local orig_get_config, orig_set_hl

  local function stub_config(config_by_name)
    orig_get_config = connections.get_connection_config
    connections.get_connection_config = function(name) return config_by_name[name] end
  end

  before_each(function()
    orig_set_hl = vim.api.nvim_set_hl
    local set_calls = {}
    vim.api.nvim_set_hl = function(ns, name, opts)
      set_calls[#set_calls + 1] = { name = name, opts = opts }
      return true
    end
    -- expose the counter without leaking a mutable upvalue into assertions
    stub_config({
      ["colored"] = { color = "#98c379" },
    })
    _G._set_hl_calls = set_calls
  end)

  after_each(function()
    vim.api.nvim_set_hl = orig_set_hl
    connections.get_connection_config = orig_get_config
    vim.api.nvim_command("doautocmd ColorScheme")  -- drop the memo cache
    _G._set_hl_calls = nil
  end)

  local function set_hl_count()
    return #_G._set_hl_calls
  end

  it("derives the group from color / link / bg", function()
    stub_config({
      ["a"] = { color = "#111111" },
      ["b"] = { link = "Statement" },
      ["c"] = { color = "Normal", bg = "#222222" },
      ["plain"] = {},  -- no color/link: no group at all
    })
    -- the group name sanitizes non-word chars away ("a-b" would collide)
    assert.equals("PosteRedisCtxa", statusline.get_ctx_color("a"))
    assert.equals("PosteRedisCtxb", statusline.get_ctx_color("b"))
    assert.equals("PosteRedisCtxc", statusline.get_ctx_color("c"))
    assert.is_nil(statusline.get_ctx_color("plain"))
    assert.is_nil(statusline.get_ctx_color(nil))
    assert.is_nil(statusline.get_ctx_color(""))
  end)

  it("memoizes: repeated calls do not re-apply nvim_set_hl", function()
    assert.equals("PosteRedisCtxcolored", statusline.get_ctx_color("colored"))
    local after_first = set_hl_count()
    assert.is_true(after_first >= 1)
    for _ = 1, 50 do statusline.get_ctx_color("colored") end
    assert.equals(after_first, set_hl_count(),
      "unchanged fingerprint must never re-apply the highlight")
  end)

  it("re-applies when the connections.toml fingerprint changes", function()
    statusline.get_ctx_color("colored")
    local after_first = set_hl_count()
    -- the "user" edits connections.toml: same name, new color
    stub_config({ ["colored"] = { color = "#ff0000" } })
    assert.equals("PosteRedisCtxcolored", statusline.get_ctx_color("colored"))
    assert.equals(after_first + 1, set_hl_count())
    -- the definition carries the new fg
    assert.equals("#ff0000", _G._set_hl_calls[#_G._set_hl_calls].opts.fg)
  end)

  it("drops the cache on ColorScheme so definitions re-derive", function()
    statusline.get_ctx_color("colored")
    local after_first = set_hl_count()
    vim.api.nvim_command("doautocmd ColorScheme")
    statusline.get_ctx_color("colored")
    assert.equals(after_first + 1, set_hl_count(),
      "the definition must be re-applied against the new scheme")
  end)

  it("negative results are not cached as stale positives", function()
    assert.is_nil(statusline.get_ctx_color("late"))  -- not configured yet
    stub_config({ ["late"] = { color = "#98c379" } })
    assert.equals("PosteRedisCtxlate", statusline.get_ctx_color("late"))
  end)

  it("treats an unknown group-name color as a raw value, not a link", function()
    -- nvim_get_hl returns an empty table for missing groups (truthy): the
    -- old check linked every bare color to a possibly nonexistent group
    stub_config({
      ["raw"] = { color = "98c379" },  -- no leading #, no such group
    })
    statusline.get_ctx_color("raw")
    local calls = _G._set_hl_calls
    local last = calls[#calls]
    assert.equals("PosteRedisCtxraw", last.name)
    assert.equals("98c379", last.opts.fg)
    assert.is_nil(last.opts.link)
  end)

  it("drops an invalid bg instead of poisoning the whole definition", function()
    stub_config({
      ["badbg"] = { color = "#112233", bg = "NoSuchGroupAtAll" },
    })
    statusline.get_ctx_color("badbg")
    local calls = _G._set_hl_calls
    local last = calls[#calls]
    assert.equals("PosteRedisCtxbadbg", last.name)
    assert.equals("#112233", last.opts.fg)
    assert.is_nil(last.opts.bg)
  end)
end)

---------------------------------------------------------------------------
-- mini.statusline wiring (poste.nvim family dissolution): scope-guard,
--- fall-through chain discipline, % escaping, reload idempotency.
---------------------------------------------------------------------------
local redis_state = require("poste-redis.state")

--- Fake mini.statusline with just enough surface for the wiring.
local function fake_mini()
  local fake = {
    section_fileinfo = function() return "[orig]" end,
    config = { content = { active = function() return "[orig-active]" end } },
    combine_groups = function(groups)
      local out = {}
      for _, g in ipairs(groups) do
        if type(g) == "string" then
          out[#out + 1] = g
        elseif g.strings then
          if g.hl then out[#out + 1] = "%#" .. g.hl .. "#" end
          for _, s in ipairs(g.strings) do out[#out + 1] = tostring(s) end
        end
      end
      return table.concat(out)
    end,
    section_mode = function() return "M", "ModeHl" end,
    section_git = function() return "G" end,
    section_diff = function() return "D" end,
    section_diagnostics = function() return "DG" end,
    section_lsp = function() return "L" end,
    section_filename = function() return "F" end,
    section_location = function() return "LOC" end,
    section_searchcount = function() return "S" end,
  }
  package.loaded["mini.statusline"] = fake
  return fake
end

--- Fresh module + fake mini, then run setup() and pump the scheduled wiring.
local function fresh_setup()
  local ms = fake_mini()
  package.loaded["poste-redis.statusline"] = nil
  local sl = require("poste-redis.statusline")
  sl.setup()
  vim.wait(100, function() return vim.g.poste_redis_statusline_wired end)
  return sl, ms
end

--- A .redis source buffer current in the window: its file branch resolves
--- through the global-context fallback (context.lua's USE-less path).
local function current_redis_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "poste_redis"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "GET k" })
  vim.api.nvim_set_current_buf(buf)
  return buf
end

local function current_plain_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  return buf
end

describe("poste-redis statusline wiring", function()
  before_each(function()
    vim.g.poste_redis_statusline_wired = nil
  end)

  after_each(function()
    package.loaded["mini.statusline"] = nil
    vim.g.poste_redis_statusline_wired = nil
    redis_state.context.connection = nil
    redis_state.context.db = nil
    vim.cmd("enew")
  end)

  it("renders the context on a .redis source buffer", function()
    redis_state.context.connection = "local"
    local _, ms = fresh_setup()
    current_redis_buf()

    local fileinfo = ms.section_fileinfo({})
    assert.match("local", fileinfo)

    local active = ms.config.content.active()
    assert.match("local", active)
    assert.match("MiniStatuslineDevinfo", active)  -- layout intact
  end)

  it("falls through on plain buffers even with a global context set", function()
    -- the global session fallback must NOT claim arbitrary buffers
    redis_state.context.connection = "globalconn"
    local _, ms = fresh_setup()
    current_plain_buf()

    assert.equals("[orig]", ms.section_fileinfo({}))
    assert.equals("[orig-active]", ms.config.content.active())
  end)

  it("escapes % in the context text (statusline E539)", function()
    redis_state.context.connection = "100%"
    local _, ms = fresh_setup()
    current_redis_buf()

    local out = ms.section_fileinfo({})
    assert.match("100%%", out, 1, true)
    assert.has_no.errors(function()
      vim.api.nvim_eval_statusline(out, {})
    end)
  end)

  it("does not re-capture the hooks when setup runs twice", function()
    local sl, ms = fresh_setup()
    local active1 = ms.config.content.active

    sl.setup()  -- same module instance
    assert.equals(active1, ms.config.content.active, "hooks must not be re-wrapped")

    -- a module reload must also be a no-op: the vim.g guard owns the
    -- idempotency across reloads
    package.loaded["poste-redis.statusline"] = nil
    require("poste-redis.statusline").setup()
    vim.wait(50)
    assert.equals(active1, ms.config.content.active,
      "a reload must not stack a second wrapper")
  end)

  it("chains: a sibling wrapper installed earlier still renders", function()
    local ms = fake_mini()
    ms.section_fileinfo = function() return "%#PosteDbSqlCtxprod# prod/blog " end
    ms.config.content.active = function() return "sibling-active" end

    package.loaded["poste-redis.statusline"] = nil
    local sl = require("poste-redis.statusline")
    sl.setup()
    vim.wait(100, function() return vim.g.poste_redis_statusline_wired end)

    current_plain_buf()
    assert.match("PosteDbSqlCtxprod", ms.section_fileinfo({}))
    assert.equals("sibling-active", ms.config.content.active())

    redis_state.context.connection = "local"
    current_redis_buf()
    assert.match("local", ms.config.content.active(),
      "redis still renders its own context on redis windows")
  end)
end)
