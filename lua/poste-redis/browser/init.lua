--- Redis key browser window (M2, P1-1/P1-2).
---
--- Layout (v3):
---   <search>            <- search bar (line 1): <leader>/ focuses it, <CR>
---                          runs async.search on the selected db, empty + <CR>
---                          clears it. The bar is a fixed icon prefix; the
---                          "filter by key" cue is extmark ghost text and a
---                          committed query stays on the line in a hint
---                          highlight — neither is ever part of the query.
---                          `/` is left alone for nvim's own buffer search.
---   [ db 0]           <- db select (line 2): <Space> pops a dropdown list;
---                          picking a db re-scans it and backfills the name.
---   ------              <- separator (line 3) between header and key rows.
---   tree                <- the selected db's groups + flat keys as top level
---                          (the db node itself is the hidden display_root).
---                          While a search is active the results node is the
---                          display root instead: matched keys REPLACE the
---                          tree; <Esc> (search_clear) restores it.
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

--- Multi-select (poste-db db-browser pattern): <Tab> toggles a node into the
--- selection (restricted to nodes under the current db), <Esc> exits, D
--- batch-deletes the selection. Selected nodes render with a ✓ marker.
local multi_select = { active = false, selected = {} }

--- Header text for line 2 (db select).
local function db_select_text()
  -- \239\135\128 = db icon U+F1C0 (explicit escape: reviewable bytes)
  return "[\239\135\128 db " .. tostring(current_db) .. "]"
end

--- Header text for line 1 (search bar): the committed query only — the icon
--- is virt text added by tree.decorate_search_line, never buffer text. While
--- the user is editing the line the buffer text is whatever they typed;
--- render_tree keeps it when a render fires mid-edit.
local function search_bar_text()
  return search_query
end

--- Header text for line 3 (separator rule): dashes spanning the browser
--- window so the key rows below read as a separate area. The dash count is
--- width-derived, and the run is clamped so it always fits ONE screen line —
--- a run reaching the window's last column wraps onto a second line, which
--- is what made the rule look doubled in narrow splits. browser_win can be a
--- stale handle after :q / split churn, so re-resolve from the buffer.
--- @return string
local function separator_text()
  local win = browser_win
  if not win or not vim.api.nvim_win_is_valid(win) then
    win = browser_buf and vim.api.nvim_buf_is_valid(browser_buf) and vim.fn.bufwinid(browser_buf) or nil
  end
  if not win or win == -1 then return string.rep("-", 20) end

  -- width - 6 spans the split with a margin; the floor of 8 applies only
  -- when the window is wide enough — never let the run reach width (wrap).
  local width = vim.api.nvim_win_get_width(win)
  local dashes = math.max(width - 6, math.min(8, width - 1))
  return string.rep("-", math.max(dashes, 1))
end

--- The node rendered as the tree top level. While a search is active the
--- results node takes over — matched keys REPLACE the tree; on clear the db
--- node comes back with its children untouched.
local function display_root_node()
  if current_db_node and current_db_node._search_results then
    return current_db_node._search_results
  end
  return current_db_node
end

local function render_tree()
  if not browser_buf or not vim.api.nvim_buf_is_valid(browser_buf) then return end
  local search_line = search_bar_text()
  if search_active then
    -- a render fired mid-edit (paced SCAN batch): keep the in-progress text
    search_line = vim.api.nvim_buf_get_lines(browser_buf, 0, 1, false)[1] or search_line
  end
  tree.header_lines = { search_line, db_select_text(), separator_text() }
  tree.display_root = display_root_node()
  line_to_node = tree.render_tree(browser_buf, line_to_node, { tree.display_root },
    multi_select.active and multi_select or nil)
  if not search_active then
    tree.decorate_search_line(browser_buf, search_query)
  end
  tree.decorate_separator(browser_buf, tree.header_lines[3])
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

local current_node  -- forward decl (defined in "Keymap handlers")

--- Expand a group node's children (lazy scan_group). Keys are leaves; the db
--- lives in the header select, not the tree. In nested view the subfolders
--- created by scan_group recurse here the same way — each is its own lazy
--- scan_group until the SPLIT_NEST cap turns further keys into flat leaves.
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

--- <Tab>: toggle multi-select on the node under the cursor. The first press
--- enters multi-select mode; every selected node renders with a ✓ marker.
--- Selection is restricted to nodes under the current db (single folder).
local function toggle_multi_select()
  local node = current_node()
  if not node or not current_db_node then return end
  if node.node_type ~= "key" and node.node_type ~= "group" then return end
  if not multi_select.active then
    multi_select.active = true
    multi_select.selected = {}
  end
  if multi_select.selected[node] then
    multi_select.selected[node] = nil
  else
    multi_select.selected[node] = true
  end
  render_tree()
end

--- Leave multi-select mode (Esc while active, or after a batch delete).
local function exit_multi_select()
  if not multi_select.active then return end
  multi_select.active = false
  multi_select.selected = {}
  render_tree()
end

--- D with an active selection: batch-delete every selected node's keys after
--- one confirm; without a selection D keeps the single-prefix delete.
local function delete_selected_or_prefix()
  if multi_select.active and next(multi_select.selected) then
    local nodes = {}
    for node in pairs(multi_select.selected) do nodes[#nodes + 1] = node end
    require("poste-redis.browser.actions").delete_nodes(nodes, {
      db_node = current_db_node,
      render = render_tree,
      on_done = exit_multi_select,
    })
    return
  end
  local node = current_node()
  if not node or node.node_type ~= "group" then
    vim.notify("Move to a group node to delete by prefix",
      vim.log.levels.INFO, { title = redis_state.TITLE })
    return
  end
  require("poste-redis.browser.actions").delete_prefix(node, {
    db_node = current_db_node,
    render = render_tree,
  })
end

----------------------------------------------------------------------
-- Keymap handlers
----------------------------------------------------------------------

-- NOTE: assigned (not `local function`) so it fills the forward-declared
-- local at the top of "Node actions" — a second `local` would shadow it with
-- nil (AGENTS.md local-fn hoisting pitfall).
function current_node()
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
        -- i is a slot in line_to_node; the buffer line is offset by the
        -- header lines (parity with get_node_at_line). Without the offset
        -- the cursor landed HEADER_LINES rows above the collapsed node.
        vim.api.nvim_win_set_cursor(0, { i + tree.HEADER_LINES, 0 })
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

--- r: reload the current db's keys. Any active search is cleared — the fresh
--- scan rebuilds the unfiltered tree.
local function refresh_node()
  if not current_db_node or not current_conn then return end
  M.search_clear()
  current_db_node.children = nil
  async.scan_keys(current_db_node, current_conn.url, current_conn.name)
end

--- <leader>/: enter search state — focus the search bar on line 1, insert
--- mode (typed text lands after the fixed icon prefix, NOT the command
--- line). <CR> runs async.search on the current db and loses focus; empty +
--- <CR> clears the search; <Esc> cancels. `/` is untouched so nvim's own
--- buffer search keeps working.
local search_commit  -- forward declarations (AGENTS.md: local fn hoisting)
local search_cancel
local function search_enter()
  if not browser_buf or not vim.api.nvim_buf_is_valid(browser_buf) then return end
  local win = vim.fn.bufwinid(browser_buf)
  if win ~= -1 then vim.api.nvim_set_current_win(win) end

  search_active = true
  tree.set_header_line(browser_buf, search_query, 1)
  -- The icon is idle-only virt text. While editing it is dropped so the
  -- caret (at the true EOL) can never sit on or before it — the bar is
  -- just the query, and insert mode is entered automatically.
  tree.decorate_search_line(browser_buf, search_query, true)
  vim.api.nvim_set_option_value("modifiable", true, { buf = browser_buf })
  vim.keymap.set("i", "<CR>", search_commit, { buffer = browser_buf, silent = true })
  vim.keymap.set("i", "<Esc>", search_cancel, { buffer = browser_buf, silent = true })
  -- Land on the search line FIRST: :startinsert! works like "A" (append at the
  -- EOL of the line the caret is on), so without this it would put the tree
  -- row under the cursor into insert mode instead. From (1,0) it reaches the
  -- search line's TRUE EOL and Insert mode starts after this function returns
  -- (no i/A needed). normal! A must not be used — insert mode entered via
  -- :normal does not survive a mapping callback (:help :startinsert).
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd("startinsert!")
end

--- Parse the query out of the search bar line: trim whitespace. The icon is
--- virt text, never in the buffer, but a stray icon (pasted, or a stale
--- pre-virt bar) is still stripped defensively — the icon must never leak
--- into a query.
--- @param line string
--- @return string
local function parse_search_line(line)
  line = line or ""
  -- strip the fixed icon prefix repeatedly (an already-doubled bar repairs
  -- itself), plus a bare icon alone from a deleted separator space — the
  -- icon must never survive into the committed query
  while line:sub(1, #tree.SEARCH_PREFIX) == tree.SEARCH_PREFIX do
    line = line:sub(#tree.SEARCH_PREFIX + 1)
  end
  if line:sub(1, #tree.SEARCH_ICON) == tree.SEARCH_ICON then
    line = line:sub(#tree.SEARCH_ICON + 1)
  end
  line = line:gsub("^%s+", "")
  return (line:gsub("%s+$", ""))
end

--- <CR> in the search bar: read the query, run async.search, return to tree.
-- NOTE: assigned (not `local function`) so it fills the forward-declared
-- local `search_commit` that search_enter captured — a second `local` here
-- would shadow it with nil (AGENTS.md local-fn hoisting pitfall).
function search_commit()
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
-- NOTE: assigned (not `local function`) — see search_commit.
function search_cancel()
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

  --- The separator dash count derives from the window width, so a split
  --- resize must refresh line 3 — otherwise a rule written for a wider
  --- split wraps onto two lines once the browser narrows. Refresh only the
  --- separator (cheap), never the whole tree. Skipped while the search bar
  --- is being edited: modifiable flips mid-insert would break typing; the
  --- commit re-renders with the fresh width anyway.
  local resize_group = vim.api.nvim_create_augroup("PosteRedisBrowserResize", { clear = true })
  vim.api.nvim_create_autocmd("WinResized", {
    group = resize_group,
    callback = function()
      if search_active then return end
      if not browser_buf or not vim.api.nvim_buf_is_valid(browser_buf) then return end
      if vim.fn.bufwinid(browser_buf) == -1 then return end
      tree.set_header_line(browser_buf, separator_text(), 3)
    end,
  })

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
  k = config.get_keymap("redis_browser", "search", "<leader>/")
  if k then vim.keymap.set("n", k, search_enter, opts) end
  k = config.get_keymap("redis_browser", "search_clear", "<Esc>")
  if k then
    vim.keymap.set("n", k, function()
      if search_active then
        search_cancel()
      elseif multi_select.active then
        exit_multi_select()
      else
        M.search_clear()
      end
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
      if not node then return end
      if node.node_type == "group" then
        -- delete the node and every key under it (y/n confirm)
        actions.delete_node(node, action_ctx())
      elseif node.node_type == "key" then
        actions.delete_key(node, action_ctx())
      end
    end, opts)
  end
  k = config.get_keymap("redis_browser", "delete_prefix", "D")
  if k then
    vim.keymap.set("n", k, delete_selected_or_prefix, opts)
  end
  k = config.get_keymap("redis_browser", "multi_select_toggle", "<Tab>")
  if k then vim.keymap.set("n", k, toggle_multi_select, opts) end
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
  k = config.get_keymap("redis_browser", "info", "i")
  if k then
    vim.keymap.set("n", k, function()
      local node = current_node()
      if not node or not current_conn then return end
      require("poste-redis.browser.info").show(node, { url = current_conn.url })
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
        "  r     reload db keys (clears search)",
        "  <leader>/>  filter keys by sub-path (matches cache:a for 'cache')",
        "  <Esc>  clear search",
        "  <Space>  select database",
        "  d     delete key (confirm)",
        "  D     delete all keys under prefix (count + confirm)",
        "  <Tab> multi-select nodes (same db); D deletes all selected",
        "  i     node info (count / memory / ttl)",
        "  t     show/edit TTL (secs, -1 = PERSIST)",
        "  R     rename key (conflict-checked)",
        "  q     close browser",
        "  :PosteRedisBrowserView [flat|flatten|nested]  switch view mode",
        "          flatten = one folder per first : segment (方案A)",
        "          nested  = folders nest per : segment (方案B)",
        "  (/ stays nvim's own buffer search)",
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

  -- bufwinid returns a window id (winid), which nvim_set_current_win /
  -- nvim_win_is_valid / nvim_win_close all expect; bufwinnr returns only a
  -- window number and must not be used here.
  local win = vim.fn.bufwinid(buf)
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

--- Toggle between flatten (方案A: one folder per first `:`-segment, keys flat
--- underneath) and nested (方案B: folders nest per segment). Any active search
--- is cleared first. Use :PosteRedisBrowserView with an argument
--- (flat|flatten|nested) for a specific mode.
---
--- Switches view by RE-SCANNING the db (same as `r`): rebuilding from the
--- rendered tree would walk only LOADED children, so keys inside unexpanded
--- folders/groups (children = nil) were silently dropped on every toggle —
--- the tree looked empty until a manual refresh.
--- @param mode? string|nil "flat" | "flatten" | "nested" (nil = toggle)
function M.toggle_view(mode)
  local applied
  if mode and (mode == "flat" or mode == "flatten" or mode == "nested") then
    applied = async.set_view_mode(mode)
  else
    applied = async.toggle_view_mode()
  end
  M.search_clear()
  if current_db_node and current_conn then
    current_db_node.children = nil
    async.scan_keys(current_db_node, current_conn.url, current_conn.name)
  end
  local label = applied == "nested" and "Nested folders"
    or (applied == "flatten" and "Flatten folders"
    or "Flat view — :PosteRedisBrowserView [flatten|nested] for folders")
  vim.notify(label, vim.log.levels.INFO, { title = redis_state.TITLE })
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
    view_mode = async.view_mode(),
  }
end

M._test = {
  toggle_node = toggle_node,
  expand_node = expand_node,
  collapse_node = collapse_node,
  expand_or_child = expand_or_child,
  collapse_or_parent = collapse_or_parent,
  split_command = split_command,
  search_enter = search_enter,
  search_commit = search_commit,
  search_cancel = search_cancel,
  pick_db = pick_db,
  select_db = select_db,
  toggle_multi_select = toggle_multi_select,
  exit_multi_select = exit_multi_select,
  multi_select_state = function() return multi_select end,
  parse_search_line = parse_search_line,
  search_bar_text = search_bar_text,
  db_select_text = db_select_text,
  separator_text = separator_text,
  display_root_node = display_root_node,
}

return M
