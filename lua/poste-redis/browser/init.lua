--- Redis key browser window (M2, P1-1/P1-2) — the FACADE.
---
--- Layout (v5):
---   winbar              <- plain connection name + db scope (orange), both
---                          right-aligned chrome; <Space> pops the db picker
---                          dropdown anywhere in the buffer
---   <search>            <- search bar (line 1): <leader>/ focuses it, <CR>
---                          runs async.search on the selected db, empty + <CR>
---                          clears it. The bar is a fixed icon prefix; the
---                          "filter by key" cue is extmark ghost text and a
---                          committed query stays on the line in a hint
---                          highlight — neither is ever part of the query.
---                          `/` is left alone for nvim's own buffer search.
---   ------              <- separator (line 2) between header and key rows.
---   tree                <- the selected db's groups + flat keys as top level
---                          (the db node itself is the hidden display_root).
---                          While a search is active the results node is the
---                          display root instead: the matched keys REPLACE
---                          the tree, bucketed under their real folders;
---                          <Esc> (search_clear) restores it.
---   [pinned overlay]    <- header lines 1-2 are mirrored into a borderless
---                          float pinned to the window's top rows
---                          (browser/header_bar), so the filter bar + separator
---                          stay visible while the tree scrolls. Hidden while
---                          the bar is being edited (the caret needs line 1).
---
--- First open (no connection chosen yet): the window lists the connections.toml
--- entries INSTEAD of the tree. Nothing is auto-picked — <CR> on a row makes
--- it the context, lands on db 0, and swaps the list for the layout above.
---
--- This file owns the window/buffer lifecycle, the render pipeline, the
--- keymaps and the public API. The mutable state lives in browser/state.lua
--- (shared with the submodules); concerns extracted from the old monolith:
---   browser/searchbar.lua  search editing + cursor clamp
---   browser/picker.lua     first-open connections list
---   browser/reveal.lua     jump-to-key walker
---   browser/header_bar.lua pinned header overlay
---
--- All I/O goes through browser/async.lua on the persistent redis-session
--- transport. The browser is scoped to ONE connection + ONE db at a time.

local config = require("poste-redis.config")
local constants = require("poste-redis.constants")
local tree = require("poste-redis.browser.tree")
local async = require("poste-redis.browser.async")
local scan = require("poste-redis.browser.scan")
local session_conn = require("poste-redis.session_conn")
local redis_state = require("poste-redis.state")
local header_bar = require("poste-redis.browser.header_bar")
local state = require("poste-redis.browser.state")
local searchbar = require("poste-redis.browser.searchbar")
local picker = require("poste-redis.browser.picker")
local reveal = require("poste-redis.browser.reveal")

local M = {}

--- Winbar text (db scope, orange). Display-only chrome: <Space> anywhere in
--- the buffer pops the picker; picking a db re-scans it and repaints this.
local function db_select_text()
  -- \239\135\128 = db icon U+F1C0 (explicit escape: reviewable bytes)
  return "\239\135\128 db " .. tostring(state.current_db)
end

--- Paint the connection + db scope into the browser window's winbar: both
--- sit right of the `%=` split — the plain connection name hugging the orange
--- db scope. No connections.toml color here: that highlight belongs to the
--- statusline, and a colored winbar read as query chrome. The window handle
--- is re-resolved via state.window() — browser_win can be stale after :q /
--- split churn. All text is plugin-generated, no %-escaping needed.
local function update_winbar()
  local win = state.window()
  if not win then return end
  local parts = {}
  if state.conn_picker.active then
    -- no scope yet: the right side names the pending choice instead of a db
    parts[#parts + 1] = "%=%#PosteRedisBrowserWinbarDb#select connection %*"
  else
    parts[#parts + 1] = "%="
    if state.current_conn and state.current_conn.name then
      parts[#parts + 1] = state.current_conn.name .. "  "
    end
    parts[#parts + 1] = "%#PosteRedisBrowserWinbarDb#" .. db_select_text() .. " %*"
  end
  vim.api.nvim_set_option_value("winbar", table.concat(parts), { win = win })
end

--- Header text for line 2 (separator rule): dashes spanning the browser
--- window so the key rows below read as a separate area. The dash count is
--- width-derived, and the run is clamped so it always fits ONE screen line —
--- a run reaching the window's last column wraps onto a second line, which
--- is what made the rule look doubled in narrow splits.
--- @return string
local function separator_text()
  local win = state.window()
  if not win then return string.rep("-", 20) end

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
  if state.current_db_node and state.current_db_node._search_results then
    return state.current_db_node._search_results
  end
  return state.current_db_node
end

--- Auto-width: resize the browser split to fit the longest rendered row so
--- expanded key names never wrap. Grows and shrinks with the visible node set,
--- floored at the width the browser last opened at (>= browser_min_width) and
--- capped at browser_width_max_ratio of the editor columns. The separator's
--- dash run is excluded from the measurement — it derives from the window
--- width, so counting it would feed the width back into itself; anything that
--- still exceeds the cap is clipped by nowrap instead of wrapping.
local function update_browser_width()
  if not config.config.browser_auto_width then return end
  local win = state.window()
  if not win then return end

  local content = tree.last_content_width or 0
  -- header chrome to keep in view: the search bar only (the separator is
  -- width-derived and excluded; the db scope lives in the winbar)
  content = math.max(content, vim.fn.strdisplaywidth(tree.header_lines[1] or ""))
  local min_w = math.max(1, math.floor(tonumber(config.config.browser_min_width) or 30))
  min_w = math.max(min_w, state.opened_width)
  local ratio = tonumber(config.config.browser_width_max_ratio) or 0.7
  local max_w = math.max(min_w, math.floor(vim.o.columns * ratio))
  local target = math.max(min_w, math.min(content + 3, max_w))
  local cur = vim.api.nvim_win_get_width(win)
  if target ~= cur then
    pcall(vim.api.nvim_win_set_width, win, target)
  end
end

local function render_tree()
  local buf = state.browser_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  if state.conn_picker.active then
    -- picker mode: connection rows instead of the tree; line 1 is the
    -- picker cue (any stale search-bar icon extmark must go with it)
    tree.header_lines = { picker.hint_text(), separator_text() }
    tree.display_root = nil
    state.line_to_node = tree.render_tree(buf, state.line_to_node, state.conn_picker.nodes, nil)
    tree.clear_search_decoration(buf)
    tree.decorate_separator(buf, tree.header_lines[2])
    update_winbar()
    update_browser_width()
    header_bar.sync(buf, { plain = true })
    return
  end
  local search_line = state.search_query
  if state.search_active then
    -- a render fired mid-edit (paced SCAN batch): keep the in-progress text
    search_line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or search_line
  end
  tree.header_lines = { search_line, separator_text() }
  tree.display_root = display_root_node()
  state.line_to_node = tree.render_tree(buf, state.line_to_node, { tree.display_root },
    state.multi_select.active and state.multi_select or nil)
  if not state.search_active then
    tree.decorate_search_line(buf, state.search_query)
  end
  tree.decorate_separator(buf, tree.header_lines[2])
  update_winbar()
  update_browser_width()
  -- Pin the header chrome over the scrolling tree (browser/header_bar). While
  -- the bar is being edited the caret sits on line 1, under where the overlay
  -- would be — hide it until commit/cancel re-render.
  if state.search_active then
    header_bar.hide()
  else
    header_bar.sync(buf)
  end
  -- a pending key reveal resumes here: expand → render → walk (last, so a
  -- re-entrant render from an expand finishes before the outer one)
  if state.reveal_state then reveal.resume() end
end

async.render_hook = render_tree
state.render = render_tree

--- Search results build through scan's eager tree builders (see
--- async.results_build): matched keys land in their real folders instead of
--- a flat list that stripped the folder away.
async.results_build = scan.build_search_results

--- Incremental append: insert newly-arrived nodes under `node` without a
--- full re-render. Falls back to render_tree if the node isn't rendered yet.
async.append_hook = function(node, new_nodes)
  local buf = state.browser_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return false end
  local ok = tree.append_children(buf, state.line_to_node, node, new_nodes)
  if not ok then
    render_tree()
  end
  return true
end

--- <Space>: pop a dropdown listing dbs of the current connection; picking one
--- re-scans it and repaints the winbar scope.
local function pick_db()
  if not state.current_conn then return end
  local items = {}
  for db = 0, constants.REDIS_DB_COUNT - 1 do
    items[#items + 1] = { db = db, label = ("db %d"):format(db) }
  end
  vim.ui.select(items, {
    prompt = "Select database (" .. state.current_conn.name .. ")",
    format_item = function(i) return i.label end,
  }, function(choice)
    if choice then state.select_db(choice.db) end
  end)
end

----------------------------------------------------------------------
-- Node actions
----------------------------------------------------------------------

local current_node  -- forward decl (defined in "Keymap handlers")

--- Expand a group node's children (lazy scan_group). Keys are leaves; the db
--- lives in the header select, not the tree. In nested view the subfolders
--- created by scan_group recurse here the same way — each is its own lazy
--- scan_group until the browser_split_nest cap turns further keys into flat
--- leaves. Lazy headers are pre-folded to their spine's branch point by the
--- parent's scan (scan.lua respine_headers), so one expand lands there;
--- loaded chains keep folding at render time (tree.lua fold_walk).
--- @param node table group node
--- @param conn_url string
local function expand_node(node, conn_url)
  if node.node_type == "group" and not node.children then
    scan.scan_group(node, conn_url, state.current_conn and state.current_conn.name)
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
  if not node or not state.current_db_node then return end
  if node.node_type ~= "key" and node.node_type ~= "group" then return end
  if not state.multi_select.active then
    state.multi_select.active = true
    state.multi_select.selected = {}
  end
  if state.multi_select.selected[node] then
    state.multi_select.selected[node] = nil
  else
    state.multi_select.selected[node] = true
  end
  render_tree()
end

--- Leave multi-select mode (Esc while active, or after a batch delete).
local function exit_multi_select()
  if not state.multi_select.active then return end
  state.multi_select.active = false
  state.multi_select.selected = {}
  render_tree()
end

--- D with an active selection: batch-delete every selected node's keys after
--- one confirm; without a selection D keeps the single-prefix delete.
local function delete_selected_or_prefix()
  if state.conn_picker.active then return end  -- nothing to delete before a context exists
  if state.multi_select.active and next(state.multi_select.selected) then
    local nodes = {}
    for node in pairs(state.multi_select.selected) do nodes[#nodes + 1] = node end
    require("poste-redis.browser.actions").delete_nodes(nodes, {
      db_node = state.current_db_node,
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
    db_node = state.current_db_node,
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
  return tree.get_node_at_line(state.line_to_node, vim.fn.line("."))
end

local function toggle_node()
  local node = current_node()
  if not node then return end
  if state.conn_picker.active then
    -- picker rows: <CR> (and l, via expand_or_child) connects the connection
    if node.node_type == "connection" then picker.choose(node) end
    return
  end
  if node.node_type == "key" then
    require("poste-redis.browser.value").view(node, { state.current_db_node }, render_tree)
    return
  end
  if node.expanded then
    collapse_node(node)
  else
    expand_node(node, state.current_conn and state.current_conn.url)
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
    for i, n in ipairs(state.line_to_node) do
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
    local text = vim.api.nvim_buf_get_lines(state.browser_buf, buf_line - 1, buf_line, false)[1] or ""
    local depth = math.floor((text:match("^%s*") or ""):len() / 2)
    -- never treat the two header lines as a parent
    for line = buf_line - 1, tree.HEADER_LINES + 1, -1 do
      local t = vim.api.nvim_buf_get_lines(state.browser_buf, line - 1, line, false)[1] or ""
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
    local total = vim.api.nvim_buf_line_count(state.browser_buf)
    if buf_line < total then
      vim.api.nvim_win_set_cursor(0, { buf_line + 1, 0 })
    end
  end
end

--- r: reload the current db's keys. Any active search is cleared — the fresh
--- scan rebuilds the unfiltered tree.
local function refresh_node()
  if not state.current_db_node or not state.current_conn then return end
  searchbar.clear()
  state.current_db_node.children = nil
  scan.scan_keys(state.current_db_node, state.current_conn.url, state.current_conn.name)
end

----------------------------------------------------------------------
-- Buffer + window
----------------------------------------------------------------------

local function setup_browser_buffer()
  if state.browser_buf and vim.api.nvim_buf_is_valid(state.browser_buf) then
    return state.browser_buf
  end

  local buf = vim.api.nvim_create_buf(false, true)
  state.browser_buf = buf
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.api.nvim_buf_set_name(buf, "poste://redis_browser")

  --- The separator dash count derives from the window width, so a split
  --- resize must refresh line 2 — otherwise a rule written for a wider
  --- split wraps onto two lines once the browser narrows. Refresh only the
  --- separator (cheap), never the whole tree. Skipped while the search bar
  --- is being edited: modifiable flips mid-insert would break typing; the
  --- commit re-renders with the fresh width anyway.
  local resize_group = vim.api.nvim_create_augroup("PosteRedisBrowserResize", { clear = true })
  vim.api.nvim_create_autocmd("WinResized", {
    group = resize_group,
    callback = function()
      if state.search_active then return end
      if not state.browser_buf or not vim.api.nvim_buf_is_valid(state.browser_buf) then return end
      if vim.fn.bufwinid(state.browser_buf) == -1 then return end
      tree.set_header_line(state.browser_buf, separator_text(), 2)
      -- the overlay spans the window width and mirrors the separator — keep
      -- both in step with the resized split
      header_bar.sync(state.browser_buf, { plain = state.conn_picker.active })
    end,
  })

  --- Navigation clamp: the pinned header rows are chrome under the overlay
  --- float — no cursor there (browser/searchbar.clamp_cursor).
  local cursor_group = vim.api.nvim_create_augroup("PosteRedisBrowserCursor", { clear = true })
  for _, ev in ipairs({ "CursorMoved", "CursorMovedI" }) do
    vim.api.nvim_create_autocmd(ev, {
      group = cursor_group,
      buffer = buf,
      callback = searchbar.clamp_cursor,
    })
  end

  local opts = { buffer = buf, noremap = true, silent = true }
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
  if k then vim.keymap.set("n", k, searchbar.enter, opts) end
  k = config.get_keymap("redis_browser", "search_clear", "<Esc>")
  if k then
    vim.keymap.set("n", k, function()
      if state.search_active then
        searchbar.cancel()
      elseif state.multi_select.active then
        exit_multi_select()
      else
        searchbar.clear()
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
    return { db_node = state.current_db_node, render = render_tree }
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
      if not node or not state.current_conn then return end
      require("poste-redis.browser.info").show(node, { url = state.current_conn.url })
    end, opts)
  end
  k = config.get_keymap("redis_browser", "yank_key", "y")
  if k then
    vim.keymap.set("n", k, function()
      local node = current_node()
      if not node or node.node_type ~= "key" then return end
      actions.yank_key(node)
    end, opts)
  end

  k = config.get_keymap("redis_browser", "help", "g?")
  if k then
    vim.keymap.set("n", k, function()
      local lines = {
        "poste-redis key browser",
        "",
        "  (first open: pick a connection from the list, <CR> connects; db 0)",
        "  <CR>  open/close node, view key value",
        "  h     collapse / parent",
        "  l     expand / first child",
        "  r     reload db keys (clears search)",
        "  <leader>/>  filter keys by sub-path (matches cache:a for 'cache')",
        "  <Esc>  clear search",
        "  (the filter bar is pinned above the tree; <leader>/ is the only",
        "   way into it — the cursor never rests on the bar rows)",
        "  <Space>  select database",
        "  d     delete key (confirm)",
        "  D     delete all keys under prefix (count + confirm)",
        "  <Tab> multi-select nodes (same db); D deletes all selected",
        "  i     node info (count / memory / ttl)",
        "  t     show/edit TTL (secs, -1 = PERSIST)",
        "  R     rename key (conflict-checked)",
        "  y     yank key name to clipboard",
        "  q     close browser",
        "  :PosteRedisBrowserView [flat|flatten|nested]  switch view mode",
        "          flatten = one folder per first : segment (方案A)",
        "          nested  = folders nest per : segment (方案B)",
        "  (/ stays nvim's own buffer search)",
      }
      vim.api.nvim_echo(lines, true, {})
    end, opts)
  end

  return buf
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

--- Open the browser in a side split (default right, 30 cols). On the first
--- open (no connection chosen yet) the window lists the connections.toml
--- entries and waits for <CR> — nothing is auto-picked; `opts.connection`
--- ({ name, url }, from the :PosteRedisConnection / context selectors)
--- connects directly. After a choice the browser lands on db 0 and renders
--- the filter bar + separator + keys tree.
--- @param opts? table { split = "left"|"right", width = number, connection = { name, url }|nil }
function M.open(opts)
  opts = opts or {}
  local buf = setup_browser_buffer()

  -- bufwinid returns a window id (winid), which nvim_set_current_win /
  -- nvim_win_is_valid / nvim_win_close all expect; bufwinnr returns only a
  -- window number and must not be used here.
  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    local width = math.max(
      opts.width or 0,
      math.floor(tonumber(config.config.browser_min_width) or 30)
    )
    local pos = opts.split or "right"
    vim.cmd(split_command(pos, width))
    state.opened_width = width
    state.browser_win = vim.api.nvim_get_current_win()
    -- A new split copies the CURRENT window's window-local options: opened
    -- from the redis_result panel it inherited winhl=Normal:PosteRedisResultMeta
    -- (the panel's gray meta ink) and every node name rendered gray. Reset it.
    vim.api.nvim_set_option_value("winhl", "", { win = state.browser_win })
    vim.api.nvim_win_set_buf(state.browser_win, buf)
    vim.api.nvim_set_option_value("winfixwidth", true, { win = state.browser_win })
    -- one row per key: rows clip right instead of wrapping (auto-width grows
    -- the split to fit expanded content, nowrap clips anything past the cap)
    vim.api.nvim_set_option_value("wrap", false, { win = state.browser_win })
    -- no gutter: the pinned header overlay (browser/header_bar) anchors at
    -- window col 0, which must be the first TEXT column — a number/sign/fold/
    -- status column would shift the tree rows out from under the bar
    vim.api.nvim_set_option_value("number", false, { win = state.browser_win })
    vim.api.nvim_set_option_value("relativenumber", false, { win = state.browser_win })
    vim.api.nvim_set_option_value("signcolumn", "no", { win = state.browser_win })
    vim.api.nvim_set_option_value("foldcolumn", "0", { win = state.browser_win })
    vim.api.nvim_set_option_value("statuscolumn", "", { win = state.browser_win })
  else
    state.browser_win = win
    vim.api.nvim_set_current_win(win)
  end

  if not state.current_conn then
    -- a context handed in by a selector connects directly; otherwise show
    -- the in-window connections list and wait for the user's <CR>
    local c = opts.connection
    if c and c.name and c.url then
      picker.connect(c.name, c.url)
    else
      picker.show()
    end
  else
    render_tree()
  end
  return state.browser_buf
end

--- Close the browser window (session stays alive for reuse).
function M.close()
  -- drop the pinned header overlay first: floats outlive their anchor window
  header_bar.close()
  if state.browser_win and vim.api.nvim_win_is_valid(state.browser_win) then
    vim.api.nvim_win_close(state.browser_win, true)
    state.browser_win = nil
  end
  -- sessions keyed by url survive; cleanup_buf stops empty ones
  if state.browser_buf and vim.api.nvim_buf_is_valid(state.browser_buf) then
    session_conn.cleanup_buf(state.browser_buf)
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
  if state.conn_picker.active then return end  -- no db to re-scan before a connection is chosen
  local applied
  if mode and (mode == "flat" or mode == "flatten" or mode == "nested") then
    applied = async.set_view_mode(mode)
  else
    applied = async.toggle_view_mode()
  end
  searchbar.clear()
  if state.current_db_node and state.current_conn then
    state.current_db_node.children = nil
    scan.scan_keys(state.current_db_node, state.current_conn.url, state.current_conn.name)
  end
  local label = applied == "nested" and "Nested folders"
    or (applied == "flatten" and "Flatten folders"
    or "Flat view — :PosteRedisBrowserView [flatten|nested] for folders")
  vim.notify(label, vim.log.levels.INFO, { title = redis_state.TITLE })
end

--- Clear any active search results and restore the tree (public, for the
--- <Esc> normal-mode binding and programmatic use).
function M.search_clear()
  searchbar.clear()
end

--- Reveal a key in the tree (see browser/reveal.lua) and show the window.
--- @param opts table { key, connection, url?, db? }
--- @return boolean accepted
function M.reveal(opts)
  local accepted = reveal.start(opts)
  if accepted then M.open() end
  return accepted
end

--- The browser's current scope: one connection + one selected db. Used by
--- the window-scoped context resolver (poste-redis.context) so the statusline
--- mirrors the browser while its window is focused. db is nil while the
--- connections picker is up (no context chosen yet).
--- @return { connection = string|nil, db = number|nil }
function M.current_scope()
  return {
    connection = state.current_conn and state.current_conn.name,
    db = state.current_conn and state.current_db or nil,
  }
end

--- Debug info for :PosteRedisInfo.
function M.info()
  return {
    buffer = state.browser_buf,
    window = state.browser_win,
    connection = state.current_conn and state.current_conn.name,
    db = state.current_db,
    picking_connection = state.conn_picker.active,
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
  search_enter = searchbar.enter,
  search_commit = searchbar.commit,
  search_cancel = searchbar.cancel,
  pick_db = pick_db,
  select_db = state.select_db,
  choose_connection = picker.choose,
  connect_connection = picker.connect,
  show_conn_picker = picker.show,
  picker_hint_text = picker.hint_text,
  conn_picker_state = function() return state.conn_picker end,
  --- Test hook: forget the chosen context so the first-open picker path can
  --- be exercised again (browser state is module-global and persists across
  --- open/close).
  reset_scope = state.reset_scope,
  toggle_multi_select = toggle_multi_select,
  exit_multi_select = exit_multi_select,
  multi_select_state = function() return state.multi_select end,
  parse_search_line = searchbar.parse_line,
  search_bar_text = searchbar.bar_text,
  db_select_text = db_select_text,
  separator_text = separator_text,
  display_root_node = display_root_node,
  update_browser_width = update_browser_width,
  line_to_node = function() return state.line_to_node end,
  reveal_state = function() return state.reveal_state end,
  reveal_focus = reveal.reveal_focus,
}

return M
