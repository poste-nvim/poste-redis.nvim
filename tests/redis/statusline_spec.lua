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
