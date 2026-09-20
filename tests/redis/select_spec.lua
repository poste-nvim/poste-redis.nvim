--- The built-in select float must render item descriptions itself.
--- Ported from poste-db tests/sql/sql_select_spec.lua: the connection pickers
--- pass { key, name, description } rows, so the fallback float is the path a
--- user without snacks.nvim lands on.
local selector = require("poste-redis.select")

local saved_ui_select = vim.ui.select
local ui_select_called = false

local function float_wins()
  local out = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local ok, cfg = pcall(vim.api.nvim_win_get_config, win)
    if ok and cfg.relative and cfg.relative ~= "" then table.insert(out, win) end
  end
  return out
end

describe("select built-in float", function()
  before_each(function()
    ui_select_called = false
    -- a hit means the float bailed out and the picker silently degraded
    vim.ui.select = function() ui_select_called = true end
  end)

  after_each(function()
    vim.ui.select = saved_ui_select
    for _, win in ipairs(float_wins()) do pcall(vim.api.nvim_win_close, win, true) end
  end)

  it("renders descriptions inline without falling back to vim.ui.select", function()
    selector.select({
      { key = "k1", name = "cache:prod", description = "redis://127.0.0.1:6379/0" },
      "sessions",
    }, "Pick", function() end)

    assert.is_false(ui_select_called)
    local wins = float_wins()
    assert.equals(1, #wins)

    local buf = vim.api.nvim_win_get_buf(wins[1])
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    assert.truthy(text:find("cache:prod", 1, true))
    assert.truthy(text:find("redis://127.0.0.1:6379/0", 1, true))
    assert.truthy(text:find("sessions", 1, true))

    -- the description tint is an extmark, and nvim_buf_set_extmark rejects the
    -- `-1` that add/clear_namespace accept: the render aborted there, leaving
    -- the broken float open and a second vim.ui.select prompt on top of it
    local ns = vim.api.nvim_get_namespaces()["poste-redis-select"]
    assert.truthy(ns)
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
    assert.equals(1, #marks)
  end)
end)
