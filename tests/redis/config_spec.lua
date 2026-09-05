--- config spec — defaults, merge, and keymap resolution (M1 §4/§6).
local config = require("poste-redis.config")

describe("poste-redis config", function()
  local state_config_backup

  before_each(function()
    state_config_backup = vim.deepcopy(require("poste.state").config)
  end)

  after_each(function()
    config.config = vim.deepcopy(config.defaults)
    require("poste.state").config = state_config_backup
  end)

  it("exposes the M1 defaults", function()
    assert.equals(65536, config.defaults.preview_max_bytes)
    assert.equals(500, config.defaults.scan_count)
    assert.equals(500, config.defaults.value_page_size)
    assert.truthy(config.defaults.keymaps.redis_source.run)
    assert.truthy(config.defaults.keymaps.redis_result.close)
    assert.truthy(config.defaults.keymaps.redis_browser)
  end)

  it("exposes the keymaps from EXECUTION-PLAN §6", function()
    assert.equals("<CR>", config.defaults.keymaps.redis_source.run)
    assert.equals("<leader>rh", config.defaults.keymaps.redis_source.history)
    assert.equals("g?", config.defaults.keymaps.redis_source.help)
    assert.equals("<C-Space>", config.defaults.keymaps.redis_source.trigger_completion)
    assert.equals("q", config.defaults.keymaps.redis_result.close)
    assert.equals("<Tab>", config.defaults.keymaps.redis_result.next_tab)
    assert.equals("<S-Tab>", config.defaults.keymaps.redis_result.prev_tab)
    assert.equals("K", config.defaults.keymaps.redis_result.preview_cell)
    assert.equals("yy", config.defaults.keymaps.redis_result.yank_cell)
    assert.equals("yc", config.defaults.keymaps.redis_result.yank_column)
    assert.equals("<leader>/", config.defaults.keymaps.redis_result.show_search)
    assert.equals("L", config.defaults.keymaps.redis_result.next_page)
  end)

  it("merge overrides scalar options", function()
    config.merge({ preview_max_bytes = 1024 })
    assert.equals(1024, config.config.preview_max_bytes)
  end)

  it("merge deep-merges nested keymap sections", function()
    config.merge({ keymaps = { redis_source = { run = "<leader>x" } } })
    assert.equals("<leader>x", config.config.keymaps.redis_source.run)
    -- siblings survive
    assert.equals("<leader>rh", config.config.keymaps.redis_source.history)
  end)

  it("get_keymap returns the configured value", function()
    assert.equals("q", config.get_keymap("redis_result", "close"))
  end)

  it("get_keymap honors a merged override", function()
    config.merge({ keymaps = { redis_source = { run = "<leader>x" } } })
    assert.equals("<leader>x", config.get_keymap("redis_source", "run"))
  end)

  it("get_keymap returns nil for a false (disabled) binding", function()
    config.merge({ keymaps = { redis_source = { help = false } } })
    assert.is_nil(config.get_keymap("redis_source", "help"))
  end)

  it("get_keymap falls back to the default when the action is unknown", function()
    assert.equals("X", config.get_keymap("redis_source", "does_not_exist", "X"))
  end)

  it("get_keymap falls back to the default for an unknown section", function()
    assert.equals("Y", config.get_keymap("redis_unknown_section", "run", "Y"))
  end)

  it("legacy keymaps from poste.state.config win", function()
    local state = require("poste.state")
    state.config.keymaps = { redis_source = { run = "<leader>legacy" } }
    config.merge({ keymaps = { redis_source = { run = "<leader>new" } } })
    assert.equals("<leader>legacy", config.get_keymap("redis_source", "run"))
  end)

  it("legacy keymaps respect false (disabled)", function()
    local state = require("poste.state")
    state.config.keymaps = { redis_result = { close = false } }
    assert.is_nil(config.get_keymap("redis_result", "close"))
  end)

  it("format_key_string maps named keys to readable labels", function()
    assert.equals("Tab", config.format_key_string("<Tab>"))
    assert.equals("S-Tab", config.format_key_string("<S-Tab>"))
    assert.equals("Enter", config.format_key_string("<CR>"))
    assert.equals("Esc", config.format_key_string("<Esc>"))
  end)

  it("format_key_string expands <leader>", function()
    vim.g.mapleader = "\\"
    assert.equals("\\x", config.format_key_string("<leader>x"))
    vim.g.mapleader = " "
    assert.equals("<Space>y", config.format_key_string("<leader>y"))
    vim.g.mapleader = "\\"
  end)

  it("format_key_string returns the key as-is for plain chars", function()
    assert.equals("g?", config.format_key_string("g?"))
    assert.equals("K", config.format_key_string("K"))
  end)

  it("format_key_string handles empty and nil", function()
    assert.equals("", config.format_key_string(""))
    assert.equals("", config.format_key_string(nil))
  end)

  it("format_keymap resolves then formats", function()
    assert.equals("Enter", config.format_keymap("redis_source", "run"))
    assert.equals("", config.format_keymap("redis_source", "missing"))
  end)

  it("format_keymap shows a disabled binding as empty", function()
    config.merge({ keymaps = { redis_source = { run = false } } })
    assert.equals("", config.format_keymap("redis_source", "run"))
  end)
end)
