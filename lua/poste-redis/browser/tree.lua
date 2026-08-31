--- Redis key browser tree model (M2, P1-1/P1-2).
---
--- Rebuilt from the poste-db db_browser/tree.lua pattern, stripped to what
--- redis needs (no cross-satellite require — family red line). Node types:
---   connection  → a redis connection from connections.toml
---   db          → one SELECT-able database (0..15)
---   group       → a `:`-prefix bucket (tree view folds keys by prefix)
---   key         → a single key (leaf)
---
--- Flat vs tree view: in flat view keys render as leaves directly under the
--- db node; in tree view the first `:`-segment becomes a group node and keys
--- nest under it. Groups collapse/expand like any other non-leaf node.

local M = {}

local MARKER_COLLAPSED = "▸ "
local MARKER_EXPANDED = "▾ "
local MARKER_LOADING = "⋯ "

local ICON = {
  connection = "🔌",
  db = "🅳",
  group = "📁",
  key = "🔑",
}

local hl_ns = vim.api.nvim_create_namespace("poste_redis_browser")

local HEADER_LINES = 0 -- no header: the browser buffer is pure tree lines

M.HEADER_LINES = HEADER_LINES

function M.make_connection_node(conn_info)
  return {
    node_type = "connection",
    name = conn_info.name,
    full_name = conn_info.name,
    children = nil,
    expanded = false,
    loading = false,
    meta = { url = conn_info.url, dialect = conn_info.dialect },
  }
end

function M.make_db_node(item, conn_name)
  return {
    node_type = "db",
    name = tostring(item.db),
    full_name = conn_name .. "/" .. tostring(item.db),
    children = nil,
    expanded = false,
    loading = false,
    meta = { connection = conn_name, db = item.db },
  }
end

function M.make_group_node(prefix, conn_name, db)
  return {
    node_type = "group",
    name = prefix,
    full_name = conn_name .. "/" .. tostring(db) .. "/" .. prefix,
    children = nil,
    expanded = false,
    loading = false,
    meta = { connection = conn_name, db = db, prefix = prefix },
  }
end

function M.make_key_node(key, conn_name, db, opts)
  opts = opts or {}
  return {
    node_type = "key",
    name = key,
    full_name = key,
    children = nil,
    expanded = false,
    loading = false,
    meta = {
      connection = conn_name,
      db = db,
      key = key,
      type = opts.type,      -- string|hash|list|set|zset|stream|unknown
      size = opts.size,      -- TYPE/STRLEN for string, LLEN/HLEN/etc otherwise
    },
  }
end

--- Flatten a node list into display lines + a parallel node map.
--- @param nodes table[] root nodes
--- @param depth number internal
--- @param multi_select table|nil unused placeholder (redis browser has no
---   table multi-select yet; kept for tree.render parity)
--- @return string[] lines, table[] node_map
function M.flatten_tree(nodes, depth, multi_select)
  depth = depth or 0
  local lines = {}
  local node_map = {}

  for _, node in ipairs(nodes) do
    local indent = string.rep("  ", depth)
    local icon = ICON[node.node_type] or "  "

    local marker
    if node.loading then
      marker = MARKER_LOADING
    elseif node.expanded then
      marker = MARKER_EXPANDED
    elseif node.node_type == "connection" or node.node_type == "db"
        or node.node_type == "group" then
      marker = MARKER_COLLAPSED
    else
      marker = "  "
    end

    local suffix = ""
    if node.node_type == "connection" then
      suffix = ""
    elseif node.node_type == "db" then
      suffix = ""
    elseif node.node_type == "key" and node.meta and node.meta.type then
      suffix = "  " .. node.meta.type
      if node.meta.size then suffix = suffix .. " (" .. node.meta.size .. ")" end
    end

    local line = indent .. marker .. icon .. " " .. node.name .. suffix
    table.insert(lines, line)
    table.insert(node_map, node)

    if node.expanded and node.children then
      local child_lines, child_map = M.flatten_tree(node.children, depth + 1)
      for _, cl in ipairs(child_lines) do table.insert(lines, cl) end
      for _, cn in ipairs(child_map) do table.insert(node_map, cn) end
    end
  end

  return lines, node_map
end

--- Clear + re-apply browser highlights (marker + icon colors per node type).
--- @param buf number
--- @param line_to_node table[]
function M.apply_highlights(buf, line_to_node)
  vim.api.nvim_buf_clear_namespace(buf, hl_ns, 0, -1)
  for i, node in ipairs(line_to_node) do
    local text = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ""
    local marker_col = 0
    for ci = 1, #text do
      if text:byte(ci) ~= 0x20 then marker_col = ci - 1; break end
    end
    if marker_col > 0 then
      vim.api.nvim_buf_add_highlight(buf, hl_ns, "PosteRedisBrowserMarker", i - 1, marker_col, marker_col + 2)
    end
    local icon_start = marker_col + 2
    if node.node_type == "connection" then
      vim.api.nvim_buf_add_highlight(buf, hl_ns, "PosteRedisBrowserConn", i - 1, icon_start, icon_start + 2)
    elseif node.node_type == "db" then
      vim.api.nvim_buf_add_highlight(buf, hl_ns, "PosteRedisBrowserDb", i - 1, icon_start, icon_start + 2)
    elseif node.node_type == "group" then
      vim.api.nvim_buf_add_highlight(buf, hl_ns, "PosteRedisBrowserGroup", i - 1, icon_start, icon_start + 2)
    elseif node.node_type == "key" then
      vim.api.nvim_buf_add_highlight(buf, hl_ns, "PosteRedisBrowserKey", i - 1, icon_start, icon_start + 2)
    end
  end
end

--- Write the flattened tree into the browser buffer.
--- @param browser_buf number
--- @param line_to_node table[]  (in/out: replaced)
--- @param root_nodes table[]
--- @return table[] new line_to_node
function M.render_tree(browser_buf, line_to_node, root_nodes)
  if not browser_buf or not vim.api.nvim_buf_is_valid(browser_buf) then return line_to_node end

  local lines, node_map = M.flatten_tree(root_nodes)
  vim.api.nvim_set_option_value("modifiable", true, { buf = browser_buf })
  vim.api.nvim_buf_set_lines(browser_buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = browser_buf })
  M.apply_highlights(browser_buf, node_map)
  return node_map
end

--- Map a buffer line to its node (1-based buffer line).
--- @param line_to_node table[]
--- @param buf_line number
--- @return table|nil
function M.get_node_at_line(line_to_node, buf_line)
  local idx = buf_line - HEADER_LINES
  if idx < 1 or idx > #line_to_node then return nil end
  return line_to_node[idx]
end

M._test = {
  flatten_tree = M.flatten_tree,
  make_connection_node = M.make_connection_node,
  make_db_node = M.make_db_node,
  make_group_node = M.make_group_node,
  make_key_node = M.make_key_node,
}

return M
