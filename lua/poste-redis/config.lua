--- Redis plugin configuration — owns all `redis_*` defaults, keymaps, and
--- Redis-only options. Generic shared infra (binary, env, split, log) stays in
--- `poste.state`; anything Redis-specific belongs here.
local M = {}

--- Redis-only defaults. Merged with user opts in M.merge().
M.defaults = {
  -- Preview threshold for large string values: beyond this the binary marks
  -- the payload truncated and Lua renders a summary instead of the full text.
  preview_max_bytes = 65536,
  -- SCAN batch size used by the key browser (M2) and cursor-key completion.
  scan_count = 500,
  -- SCAN COUNT for db-level group-header discovery: finding distinct `:`
  -- prefixes requires walking the whole keyspace, so use a large page to cut
  -- round-trips (10k keys ≈ 11 pages vs 200 at 500). Key lists under a group
  -- still page at scan_count.
  header_scan_count = 5000,
  -- Cap on per-key TYPE lookups in the browser (key icons + type suffix).
  -- Only the first N scanned keys get typed; a 100k-key group must never
  -- turn into 100k pipelined session requests (that wedges the shared
  -- redis-session process: every later SCAN queues behind the flood).
  type_fetch_limit = 500,
  -- Max rows rendered in the key browser tree. A 100k-key group flattened
  -- into buffer lines makes every full re-render a 100k-line rewrite, which
  -- starves the session's stdout processing (browser freeze). Beyond the cap
  -- a "... N more" notice renders and the scan stops early — narrow with the
  -- sub-path search instead.
  render_max_lines = 5000,
  -- Max children rendered per expanded node (an inline "... N more" notice
  -- follows): a 100k-key group must not crowd its sibling groups out of the
  -- tree entirely.
  render_max_per_node = 500,
  -- Result panel split: share of the editor height.
  result_height_ratio = 0.4,
  -- Execute confirm heuristic: write commands always require a confirm
  -- dialog before hitting the server (P2-1). Reserved for M3; constants are
  -- defined in constants.lua.
  confirm_commands = true,
  -- Debug commands (:PosteRedisDiag, ...). Off by default.
  debug = false,
  keymaps = {
    redis_source = {
      run = "<CR>",
      history = "<leader>rh",
      help = "g?",
      trigger_completion = "<C-Space>",
      show_doc = "K",
    },
    redis_result = {
      close = "q",
      next_tab = "<Tab>",
      prev_tab = "<S-Tab>",
      -- Table grid navigation (Set/List/Hash/Zset tabs)
      move_left = "h",
      move_down = "j",
      move_up = "k",
      move_right = "l",
      first_row = "gg",
      last_row = "G",
      prev_page = "H",
      next_page = "L",
      goto_first_page = "<leader>hh",
      goto_last_page = "<leader>ll",
      preview_cell = "K",
      yank_cell = "yy",
      yank_column = "yc",
      show_search = "<leader>/",
      next_search = "n",
      prev_search = "N",
      load_full = "F",
      -- re-run the active tab's command against its recorded connection
      refresh = "r",
      -- grid editing (poste-db dataset pattern)
      edit_cell = "i",
      add_row = "o",
      delete_row = "dd",
    },
    -- Key browser (M2). Defaults land with that milestone; placeholders keep
    -- the section discoverable in :help and config docs.
    redis_browser = {
      toggle_node = "<CR>",
      move_left = "h",
      move_right = "l",
      refresh_node = "r",
      search = "<leader>/",
      search_clear = "<Esc>",
      db_select = "<Space>",
      close = "q",
      help = "g?",
      delete = "d",
      delete_prefix = "D",
      ttl = "t",
      rename = "R",
      info = "i",
      multi_select_toggle = "<Tab>",
    },
  },
}

--- Effective config (defaults + merged user opts).
M.config = vim.deepcopy(M.defaults)

--- Merge user opts into the effective config (deep for nested tables).
--- Called from poste-redis.setup().
--- @param opts table|nil
function M.merge(opts)
  opts = opts or {}
  for k, v in pairs(opts) do
    if type(v) == "table" and type(M.config[k]) == "table" then
      M.config[k] = vim.tbl_deep_extend("force", M.config[k], v)
    else
      M.config[k] = v
    end
  end
end

local KEY_DISPLAY_NAMES = {
  ["<Tab>"] = "Tab",
  ["<S-Tab>"] = "S-Tab",
  ["<CR>"] = "Enter",
  ["<Esc>"] = "Esc",
  ["<Space>"] = "<Space>",
  ["<Up>"] = "Up",
  ["<Down>"] = "Down",
  ["<Left>"] = "Left",
  ["<Right>"] = "Right",
  ["<C-Space>"] = "C-Space",
  ["<BS>"] = "BS",
}

--- Resolve a keymap for (section, action). `false` disables; nil → default.
--- Legacy: falls through to `poste.state.config.keymaps` first so overrides
--- configured via `require("poste").setup({ keymaps = {...} })` still work.
--- @param section string
--- @param action string
--- @param default string|nil
--- @return string|nil
function M.get_keymap(section, action, default)
  local ok, poste_state = pcall(require, "poste.state")
  if ok and poste_state.config and poste_state.config.keymaps
    and poste_state.config.keymaps[section] ~= nil then
    local key = poste_state.config.keymaps[section][action]
    if key ~= nil then
      if key == false then return nil end
      return key
    end
  end
  local sec = M.config.keymaps[section]
  if not sec then return default end
  local key = sec[action]
  if key == nil then return default end
  if key == false then return nil end
  return key
end

--- Format a key string for display (handles <leader> and named keys).
--- @param key string
--- @return string
function M.format_key_string(key)
  if not key or key == "" then return "" end
  if KEY_DISPLAY_NAMES[key] then return KEY_DISPLAY_NAMES[key] end
  if key:sub(1, 8) == "<leader>" then
    local leader = vim.g.mapleader or "\\"
    if leader == " " then leader = "<Space>"
    elseif leader == "\t" then leader = "<Tab>"
    elseif leader == "\r" then leader = "<CR>"
    end
    leader = KEY_DISPLAY_NAMES[leader] or leader
    return leader .. key:sub(9)
  end
  return key
end

--- Resolve and format a keymap for (section, action).
--- @param section string
--- @param action string
--- @return string
function M.format_keymap(section, action)
  local key = M.get_keymap(section, action)
  if not key then return "" end
  return M.format_key_string(key)
end

M._test = {
  get_keymap = M.get_keymap,
  format_key_string = M.format_key_string,
  format_keymap = M.format_keymap,
  merge = M.merge,
}

return M
