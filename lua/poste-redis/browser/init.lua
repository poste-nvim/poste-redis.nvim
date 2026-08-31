--- Redis key browser window (M2, P1-1/P1-2).
---
--- Rebuilt from the poste-db db_browser/init.lua pattern, stripped down:
--- connection → db → group → key tree in a side split named
--- `poste://redis_browser`. Loading goes through browser/async.lua which
--- talks to the persistent redis-session transport.

local config = require("poste-redis.config")
local tree = require("poste-redis.browser.tree")
local async = require("poste-redis.browser.async")
local session_conn = require("poste-redis.session_conn")
local redis_state = require("poste-redis.state")

local M = {}

local browser_buf = nil
local browser_win = nil
local root_nodes = {}
local line_to_node = {}
local source_buf = nil

--- Placeholder state surface (P1-2 multi-select is not in M2 scope).
local multi_select = { active = false, selected = {} }

local function render_tree()
  if not browser_buf or not vim.api.nvim_buf_is_valid(browser_buf) then return end
  line_to_node = tree.render_tree(browser_buf, line_to_node, root_nodes)
end

async.render_hook = render_tree

local function get_connection_url(conn_name)
  return require("poste-redis.connections").resolve_redis_url(conn_name)
end

----------------------------------------------------------------------
-- Node actions
----------------------------------------------------------------------

--- Expand a node's children, loading them on first expand.
--- @param node table
--- @param conn_url string
local function expand_node(node, conn_url)
  if node.node_type == "connection" then
    if not node.children then
      async.fetch_dbs(node, conn_url, function(dbs)
        if not node.children then
          node.children = {}
          for _, db in ipairs(dbs or {}) do
            local child = tree.make_db_node({ db = db }, node.name)
            child.parent = node
            table.insert(node.children, child)
          end
          render_tree()
        end
        node.expanded = true
        render_tree()
      end)
      return
    end
  elseif node.node_type == "db" then
    if not node.children then
      async.scan_keys(node, conn_url, node.meta.connection)
      -- scan_keys re-renders per batch; mark expanded for the tree shape
      node.expanded = true
      return
    end
  elseif node.node_type == "group" then
    -- keys already loaded under the group; just expand
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
    -- value view lands with P1-3; until then, show the raw value via the
    -- existing result panel (single-command exec path).
    require("poste-redis.browser.value").view(node, root_nodes, render_tree)
    return
  end
  if node.expanded then
    collapse_node(node)
  else
    local conn_url = node.meta and node.meta.connection
      and get_connection_url(node.meta.connection) or nil
    if node.node_type == "connection" then
      conn_url = node.meta and node.meta.url
    end
    if not conn_url and node.meta and node.meta.connection then
      local url, _ = get_connection_url(node.meta.connection)
      conn_url = url
    end
    if not conn_url then
      vim.notify("Cannot resolve connection for " .. node.name,
        vim.log.levels.ERROR, { title = redis_state.TITLE })
      return
    end
    expand_node(node, conn_url)
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
    for line = buf_line - 1, 1, -1 do
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

--- r: reload the node's children from redis.
local refresh_node_at  -- forward declaration (AGENTS.md: local fn hoisting)
local function refresh_node()
  local node = current_node()
  if not node then return end
  local conn_url
  if node.node_type == "connection" then
    conn_url = node.meta and node.meta.url
    node.children = nil
    node.expanded = false
    expand_node(node, conn_url)
  elseif node.node_type == "db" then
    conn_url = node.meta.connection and get_connection_url(node.meta.connection) or nil
    node.children = nil
    node.expanded = false
    expand_node(node, conn_url)
  elseif node.node_type == "group" then
    -- reload the parent db
    local parent = node.parent
    if parent then refresh_node_at(parent) end
  end
end

--- /: SCAN MATCH filter on the enclosing db node.
local function search_filter()
  local node = current_node()
  if not node then return end
  local db_node = node
  while db_node and db_node.node_type ~= "db" do db_node = db_node.parent end
  if not db_node then
    vim.notify("Move to a key under a database to filter",
      vim.log.levels.INFO, { title = redis_state.TITLE })
    return
  end
  local pattern = vim.fn.input("SCAN MATCH pattern: ")
  if pattern == "" then return end
  local conn_url = db_node.meta.connection and get_connection_url(db_node.meta.connection) or nil
  if not conn_url then return end
  async.scan_keys(db_node, conn_url, db_node.meta.connection, pattern)
end

local function refresh_node_at(node)
  if node.node_type == "db" then
    local conn_url = node.meta.connection and get_connection_url(node.meta.connection) or nil
    if conn_url then
      node.children = nil
      node.expanded = true
      async.scan_keys(node, conn_url, node.meta.connection)
    end
  elseif node.node_type == "connection" then
    node.children = nil
    node.expanded = false
    expand_node(node, node.meta and node.meta.url)
  end
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
  k = config.get_keymap("redis_browser", "close", "q")
  if k then vim.keymap.set("n", k, function() M.close() end, opts) end

  --- P1-4 write actions (delete / TTL / rename) via browser/actions.lua.
  local actions = require("poste-redis.browser.actions")
  --- Build the action context for the node under the cursor: enclosing db
  --- node (for reload) + render callback.
  local function action_ctx(node)
    local db_node = node
    while db_node and db_node.node_type ~= "db" do db_node = db_node.parent end
    return { db_node = db_node, render = render_tree }
  end
  k = config.get_keymap("redis_browser", "delete", "d")
  if k then
    vim.keymap.set("n", k, function()
      local node = current_node()
      if not node or node.node_type ~= "key" then return end
      actions.delete_key(node, action_ctx(node))
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
      actions.delete_prefix(node, action_ctx(node))
    end, opts)
  end
  k = config.get_keymap("redis_browser", "ttl", "t")
  if k then
    vim.keymap.set("n", k, function()
      local node = current_node()
      if not node or node.node_type ~= "key" then return end
      actions.set_ttl(node, action_ctx(node))
    end, opts)
  end
  k = config.get_keymap("redis_browser", "rename", "R")
  if k then
    vim.keymap.set("n", k, function()
      local node = current_node()
      if not node or node.node_type ~= "key" then return end
      actions.rename_key(node, action_ctx(node))
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
        "  r     reload node",
        "  /     SCAN MATCH filter on the enclosing db",
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

--- Open the browser in a side split (default left, 30 cols).
--- @param opts? table { source_buf = number|nil, split = "left"|"right", width = number }
function M.open(opts)
  opts = opts or {}
  source_buf = opts.source_buf or vim.api.nvim_get_current_buf()

  local buf = setup_browser_buffer()

  local win = vim.fn.bufwinnr(buf)
  if win == -1 then
    local width = opts.width or 30
    local dir = opts.split or "left"
    vim.cmd(dir .. " " .. tostring(width) .. "vnew")
    browser_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(browser_win, buf)
    vim.api.nvim_set_option_value("winfixwidth", true, { win = browser_win })
  else
    browser_win = win
    vim.api.nvim_set_current_win(win)
  end

  if #root_nodes == 0 then
    async.load_connections(function(nodes)
      root_nodes = nodes
      render_tree()
      if #nodes == 0 then
        vim.notify("No redis connections in connections.toml",
          vim.log.levels.WARN, { title = redis_state.TITLE })
      end
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
  -- rebuild child lists of all loaded db nodes
  local function rebuild(nodes)
    for _, n in ipairs(nodes or {}) do
      if n.node_type == "db" and n.children and n.meta then
        local keys = {}
        local function collect(node)
          if node.node_type == "key" then
            keys[#keys + 1] = node.name
          elseif node.children then
            for _, c in ipairs(node.children) do collect(c) end
          end
        end
        for _, c in ipairs(n.children) do collect(c) end
        n.children = nil
        require("poste-redis.browser.async")._test.build_children(n, keys, n.meta.connection, n.meta.db)
        n.expanded = true
      end
      rebuild(n.children)
    end
  end
  rebuild(root_nodes)
  render_tree()
  vim.notify(async.tree_view and "Tree view" or "Flat view",
    vim.log.levels.INFO, { title = redis_state.TITLE })
end

--- Debug info for :PosteRedisInfo.
function M.info()
  return {
    buffer = browser_buf,
    window = browser_win,
    connections = vim.tbl_count(root_nodes),
    sessions = session_conn.list(),
    tree_view = async.tree_view,
  }
end

M._test = {
  toggle_node = toggle_node,
  expand_node = expand_node,
  collapse_node = collapse_node,
}

return M
