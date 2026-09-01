--- Redis key browser window (M2, P1-1/P1-2).
---
--- Layout (v2):
---   [search]            <- search bar (line 1): <leader>/> focuses it, <CR>
---                          runs async.search on the selected db, empty + <CR>
---                          clears the search. Search operates on the db shown
---                          in the select below.
---   [ db 0]           <- db select (line 2): <Space> pops a dropdown list;
---                          picking a db re-scans it and backfills the name.
---   tree                <- the selected db's groups + flat keys as top level
---                          (the db node itself is the hidden display_root).
---
--- All I/O goes through browser/async.lua on the persistent redis-session
--- transport. The browser is scoped to ONE connection + ONE db at a time.

local config = require("poste-redis.config")
local tree = require("poste-redis.browser.tree")
local async = require("poste-redis.browser.async")
local session_conn = require("poste-redis.session_conn")
local redis_state = require("poste-redis.state")

local M = {}

local browser_buf = nil
local browser_win = nil
local line_to_node = {}
local source_buf = nil

--- Current scope: one connection, one selected db. The db node is the hidden
--- display root; its children render at the top of the tree.
local current_conn = nil       -- { name, url } | nil
local current_db = 0
local current_db_node = nil    -- tree.make_db_node(...)

--- Search state (header line 1). search_active is true while the input is
--- being edited on line 1.
local search_active = false
local search_query = ""

--- Header text for line 2 (db select).
local function db_select_text()
  return "[ db " .. tostring(current_db) .. "]"
end

--- Header text for line 1 (search bar).
local function search_bar_text()
  if search_query ~= "" then
    return "[search: " .. search_query .. "]"
  end
  return "[search]"
end

local function render_tree()
  if not browser_buf or not vim.api.nvim_buf_is_valid(browser_buf) then return end
  tree.header_lines = { search_bar_text(), db_select_text() }
  tree.display_root = current_db_node
  line_to_node = tree.render_tree(browser_buf, line_to_node, { current_db_node })
end

async.render_hook = render_tree

--- Incremental append: insert newly-arrived nodes under `node` without a
--- full re-render. Falls back to render_tree if the node isn't rendered yet.
async.append_hook = function(node, new_nodes)
  if not browser_buf or not vim.api.nvim_buf_is_valid(browser_buf) then return false end
  local ok = tree.append_children(browser_buf, line_to_node, node, new_nodes)
  if not ok then
    render_tree()
  end
  return true
end

--- Resolve the preferred connection from the current context (poste.state
--- USE / selector), falling back to the first redis connection.
--- @param nodes table[] connection nodes from async.load_connections
--- @return table|nil
local function pick_connection(nodes)
  nodes = nodes or {}
  local ok, poste_state = pcall(require, "poste.state")
  local preferred = ok and poste_state.connection
  if preferred then
    for _, n in ipairs(nodes) do
      if n.name == preferred then return n end
    end
  end
  return nodes[1]
end

--- (Re)select a db: build its node, make it the display root, and scan_keys.
--- @param db number
local function select_db(db)
  if not current_conn then return end
  current_db = db
  current_db_node = tree.make_db_node({ db = db }, current_conn.name)
  tree.display_root = current_db_node
  search_query = ""
  async.scan_keys(current_db_node, current_conn.url, current_conn.name)
  render_tree()
end

--- <Space>: pop a dropdown listing dbs of the current connection; picking one
--- re-scans it and backfills the db select line.
local function pick_db()
  if not current_conn then return end
  local items = {}
  for db = 0, 15 do
    items[#items + 1] = { db = db, label = ("db %d"):format(db) }
  end
  vim.ui.select(items, {
    prompt = "Select database (" .. current_conn.name .. ")",
    format_item = function(i) return i.label end,
  }, function(choice)
    if choice then select_db(choice.db) end
  end)
end

----------------------------------------------------------------------
-- Node actions
----------------------------------------------------------------------

--- Expand a group node's children (lazy scan_group). Keys are leaves; the db
--- lives in the header select, not the tree.
--- @param node table group node
--- @param conn_url string
local function expand_node(node, conn_url)
  if node.node_type == "group" and not node.children then
    async.scan_group(node, conn_url, current_conn and current_conn.name)
    node.expanded = true
    return
  end
  node.expanded = true
  render_tree()
end

--- Collapse a node (children stay loaded for fast re-expand).
local function collapse_node(node)
  node.expanded = false
  render_tree()
end

----------------------------------------------------------------------
-- Keymap handlers
----------------------------------------------------------------------

local function current_node()
  return tree.get_node_at_line(line_to_node, vim.fn.line("."))
end

local function toggle_node()
  local node = current_node()
  if not node then return end
  if node.node_type == "key" then
    require("poste-redis.browser.value").view(node, { current_db_node }, render_tree)
    return
  end
  if node.expanded then
    collapse_node(node)
  else
    expand_node(node, current_conn and current_conn.url)
  end
end

--- h: collapse or jump to parent (indent-based, like poste-db).
local function collapse_or_parent()
  local node = current_node()
  if not node then return end
  local is_leaf = node.node_type == "key"
  if not is_leaf and node.expanded then
    node.expanded = false
    render_tree()
    for i, n in ipairs(line_to_node) do
      if n == node then
        vim.api.nvim_win_set_cursor(0, { i, 0 })
        return
      end
    end
  else
    local buf_line = vim.fn.line(".")
    local text = vim.api.nvim_buf_get_lines(browser_buf, buf_line - 1, buf_line, false)[1] or ""
    local depth = math.floor((text:match("^%s*") or ""):len() / 2)
    -- never treat the two header lines as a parent
    for line = buf_line - 1, tree.HEADER_LINES + 1, -1 do
      local t = vim.api.nvim_buf_get_lines(browser_buf, line - 1, line, false)[1] or ""
      local d = math.floor((t:match("^%s*") or ""):len() / 2)
      if d < depth then
        vim.api.nvim_win_set_cursor(0, { line, 0 })
        return
      end
    end
  end
end

--- l: expand or jump to first child.
local function expand_or_child()
  local node = current_node()
  if not node then return end
  if node.node_type == "key" then return end
  if not node.expanded then
    toggle_node()
  else
    local buf_line = vim.fn.line(".")
    local total = vim.api.nvim_buf_line_count(browser_buf)
    if buf_line < total then
      vim.api.nvim_win_set_cursor(0, { buf_line + 1, 0 })
    end
  end
end

--- r: reload the current db's keys.
local function refresh_node()
  if not current_db_node or not current_conn then return end
  current_db_node.children = nil
  async.scan_keys(current_db_node, current_conn.url, current_conn.name)
end

--- / or <leader>/>: enter search state — focus the search bar on line 1,
--- insert mode (typed text lands in the in-buffer [search: ] bar, NOT the
--- command line). <CR> runs async.search on the current db and loses focus;
--- empty + <CR> clears the search; <Esc> cancels.
local search_commit  -- forward declarations (AGENTS.md: local fn hoisting)
local search_cancel
local function search_enter()
  if not browser_buf or not vim.api.nvim_buf_is_valid(browser_buf) then return end
  local win = vim.fn.bufwinnr(browser_buf)
  if win ~= -1 then vim.api.nvim_set_current_win(win) end

  search_active = true
  local placeholder = "[search: " .. search_query .. "]"
  tree.set_header_line(browser_buf, placeholder, 1)
  vim.api.nvim_set_option_value("modifiable", true, { buf = browser_buf })
  -- place the cursor right after the prompt so typing appends the sub-path
  local col = #("[search: ") + #search_query
  vim.api.nvim_win_set_cursor(0, { 1, col })
  vim.keymap.set("i", "<CR>", search_commit, { buffer = browser_buf, silent = true })
  vim.keymap.set("i", "<Esc>", search_cancel, { buffer = browser_buf, silent = true })
  vim.cmd.startinsert()
end

--- /: same as <leader>/> — both focus the in-buffer search bar (no command-line
--- prompt). Kept as a separate name so users can remap them independently.
local function search_filter()
  search_enter()
end

--- Parse the query out of a "[search: <q>]" line (tolerant of missing brackets).
--- @param line string
--- @return string
local function parse_search_line(line)
  local q = line:match("%[search:%s*(.-)%s*%]")
  if q then return q end
  q = line:gsub("^%s*%[search:%s*", ""):gsub("%s*%]$", "")
  return q:gsub("%s+$", "")
end

--- <CR> in the search bar: read the query, run async.search, return to tree.
local function search_commit()
  if not browser_buf or not vim.api.nvim_buf_is_valid(browser_buf) then return end
  local line = vim.api.nvim_buf_get_lines(browser_buf, 0, 1, false)[1] or ""
  local query = parse_search_line(line)
  vim.cmd.stopinsert()
  vim.keymap.del("i", "<CR>", { buffer = browser_buf })
  vim.keymap.del("i", "<Esc>", { buffer = browser_buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = browser_buf })
  search_active = false
  if query == "" then
    M.search_clear()
    return
  end
  search_query = query
  if current_db_node and current_conn then
    async.search(current_db_node, current_conn.url, current_conn.name, query)
  end
  render_tree()
end

--- <Esc> in the search bar: cancel, clear any results, restore the tree.
local function search_cancel()
  if browser_buf and vim.api.nvim_buf_is_valid(browser_buf) then
    vim.cmd.stopinsert()
    vim.keymap.del("i", "<CR>", { buffer = browser_buf })
    vim.keymap.del("i", "<Esc>", { buffer = browser_buf })
    vim.api.nvim_set_option_value("modifiable", false, { buf = browser_buf })
  end
  search_active = false
  search_query = ""
  if current_db_node then async.search_clear(current_db_node) end
  render_tree()
end

----------------------------------------------------------------------
-- Buffer + window
----------------------------------------------------------------------

local function setup_browser_buffer()
  if browser_buf and vim.api.nvim_buf_is_valid(browser_buf) then return browser_buf end

  browser_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = browser_buf })
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = browser_buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = browser_buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = browser_buf })
  vim.api.nvim_buf_set_name(browser_buf, "poste://redis_browser")

  local opts = { buffer = browser_buf, noremap = true, silent = true }
  local k
  k = config.get_keymap("redis_browser", "toggle_node", "<CR>")
  if k then vim.keymap.set("n", k, toggle_node, opts) end
  k = config.get_keymap("redis_browser", "move_left", "h")
  if k then vim.keymap.set("n", k, collapse_or_parent, opts) end
  k = config.get_keymap("redis_browser", "move_right", "l")
  if k then vim.keymap.set("n", k, expand_or_child, opts) end
  k = config.get_keymap("redis_browser", "refresh_node", "r")
  if k then vim.keymap.set("n", k, refresh_node, opts) end
  k = config.get_keymap("redis_browser", "search_filter", "/")
  if k then vim.keymap.set("n", k, search_filter, opts) end
  k = config.get_keymap("redis_browser", "search", "<leader>/")
  if k then vim.keymap.set("n", k, search_enter, opts) end
  k = config.get_keymap("redis_browser", "search_clear", "<Esc>")
  if k then
    vim.keymap.set("n", k, function()
      if search_active then search_cancel() else M.search_clear() end
    end, opts)
  end
  k = config.get_keymap("redis_browser", "db_select", "<Space>")
  if k then vim.keymap.set("n", k, pick_db, opts) end
  k = config.get_keymap("redis_browser", "close", "q")
  if k then vim.keymap.set("n", k, function() M.close() end, opts) end

  --- P1-4 write actions (delete / TTL / rename) via browser/actions.lua.
  local actions = require("poste-redis.browser.actions")
  --- Build the action context: the current db node (reload target) + render.
  local function action_ctx()
    return { db_node = current_db_node, render = render_tree }
  end
  k = config.get_keymap("redis_browser", "delete", "d")
  if k then
    vim.keymap.set("n", k, function()
      local node = current_node()
      if not node or node.node_type ~= "key" then return end
      actions.delete_key(node, action_ctx())
    end, opts)
  end
  k = config.get_keymap("redis_browser", "delete_prefix", "D")
  if k then
    vim.keymap.set("n", k, function()
      local node = current_node()
      if not node or node.node_type ~= "group" then
        vim.notify("Move to a group node to delete by prefix",
          vim.log.levels.INFO, { title = redis_state.TITLE })
        return
      end
      actions.delete_prefix(node, action_ctx())
    end, opts)
  end
  k = config.get_keymap("redis_browser", "ttl", "t")
  if k then
    vim.keymap.set("n", k, function()
      local node = current_node()
      if not node or node.node_type ~= "key" then return end
      actions.set_ttl(node, action_ctx())
    end, opts)
  end
  k = config.get_keymap("redis_browser", "rename", "R")
  if k then
    vim.keymap.set("n", k, function()
      local node = current_node()
      if not node or node.node_type ~= "key" then return end
      actions.rename_key(node, action_ctx())
    end, opts)
  end

  k = config.get_keymap("redis_browser", "help", "g?")
  if k then
    vim.keymap.set("n", k, function()
      local lines = {
        "poste-redis key browser",
        "",
        "  <CR>  open/close node, view key value",
        "  h     collapse / parent",
        "  l     expand / first child",
        "  r     reload db keys",
        "  /     search by sub-path (cache matches cache:a)",
        "  <leader>/>  search by sub-path (bench:a:b:c)",
        "  <Esc>  clear search",
        "  <Space>  select database",
        "  d     delete key (confirm)",
        "  D     delete all keys under prefix (count + confirm)",
        "  t     show/edit TTL (secs, -1 = PERSIST)",
        "  R     rename key (conflict-checked)",
        "  q     close browser",
      }
      vim.api.nvim_echo(lines, true, {})
    end, opts)
  end

  return browser_buf
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

--- Resolve the window command for opening the browser. Uses `vsplit` so
--- the source buffer stays visible in its own window.
--- @param split string|nil "left" or "right"
--- @param width number
--- @return string
local function split_command(split, width)
  local pos = split == "left" and "topleft" or "botright"
  return pos .. " " .. tostring(width) .. "vsplit"
end

--- Open the browser in a side split (default right, 30 cols). Scopes to the
--- preferred redis connection (poste.state.connection, else first) and db 0.
--- @param opts? table { source_buf = number|nil, split = "left"|"right", width = number }
function M.open(opts)
  opts = opts or {}
  source_buf = opts.source_buf or vim.api.nvim_get_current_buf()

  local buf = setup_browser_buffer()

  local win = vim.fn.bufwinnr(buf)
  if win == -1 then
    local width = opts.width or 30
    local pos = opts.split or "right"
    vim.cmd(split_command(pos, width))
    browser_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(browser_win, buf)
    vim.api.nvim_set_option_value("winfixwidth", true, { win = browser_win })
  else
    browser_win = win
    vim.api.nvim_set_current_win(win)
  end

  if not current_conn then
    async.load_connections(function(nodes)
      local conn = pick_connection(nodes)
      if not conn then
        render_tree()
        vim.notify("No redis connections in connections.toml",
          vim.log.levels.WARN, { title = redis_state.TITLE })
        return
      end
      current_conn = { name = conn.name, url = conn.meta.url }
      select_db(0)
    end)
  else
    render_tree()
  end
  return browser_buf
end

--- Close the browser window (session stays alive for reuse).
function M.close()
  if browser_win and vim.api.nvim_win_is_valid(browser_win) then
    vim.api.nvim_win_close(browser_win, true)
    browser_win = nil
  end
  -- sessions keyed by url survive; cleanup_buf stops empty ones
  if browser_buf and vim.api.nvim_buf_is_valid(browser_buf) then
    session_conn.cleanup_buf(browser_buf)
  end
end

--- Toggle between tree view (default) and flat key view.
function M.toggle_view()
  async.tree_view = not async.tree_view
  if current_db_node and current_db_node.children then
    local keys = {}
    local function collect(node)
      if node.node_type == "key" then
        keys[#keys + 1] = node.name
      elseif node.children then
        for _, c in ipairs(node.children) do collect(c) end
      end
    end
    for _, c in ipairs(current_db_node.children) do collect(c) end
    current_db_node.children = nil
    require("poste-redis.browser.async")._test.build_children(
      current_db_node, keys, current_db_node.meta.connection, current_db_node.meta.db)
    current_db_node.expanded = true
  end
  render_tree()
  vim.notify(async.tree_view and "Tree view" or "Flat view",
    vim.log.levels.INFO, { title = redis_state.TITLE })
end

--- Clear any active search results and restore the tree (public, for the
--- <Esc> normal-mode binding and programmatic use).
function M.search_clear()
  search_active = false
  search_query = ""
  if current_db_node then async.search_clear(current_db_node) end
  render_tree()
end

--- Debug info for :PosteRedisInfo.
function M.info()
  return {
    buffer = browser_buf,
    window = browser_win,
    connection = current_conn and current_conn.name,
    db = current_db,
    sessions = session_conn.list(),
    tree_view = async.tree_view,
  }
end

M._test = {
  toggle_node = toggle_node,
  expand_node = expand_node,
  collapse_node = collapse_node,
  split_command = split_command,
  search_enter = search_enter,
  search_commit = search_commit,
  search_cancel = search_cancel,
  pick_db = pick_db,
  select_db = select_db,
  parse_search_line = parse_search_line,
  search_bar_text = search_bar_text,
  db_select_text = db_select_text,
}

return M
