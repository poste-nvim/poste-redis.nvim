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

-- Nerd-font glyphs (no emoji): marker + icons per node type.
local MARKER_COLLAPSED = " "
local MARKER_EXPANDED = " "
local MARKER_LOADING = "… "

-- Structural nodes: connection/db keep the database glyph; the group node is
-- the tree's folder in the v3 layout.
local ICON = {
  connection = "",
  db = "",
  group = "",
  key = "",
}

-- Redis key type → glyph. TYPE only reports string/zset/hash/... so the
-- subtype glyphs (bitmap/bitfield/hyperloglog/geo) are wired for a future
-- probe; today they fall back to string/zset from TYPE.
local KEY_ICON = {
  string = "",
  zset = "",
  hash = "󰘦",
  list = "",
  set = "󰸳",
  stream = "",
  bitmap = "󱗼",
  bitfield = "󱗼",
  bitfields = "󱗼",
  hyperloglog = "󱗼",
  hyperlonglong = "󱗼",
  geo = "",
}

-- Highlight group per key type: collections orange, string green, everything
-- else (stream/bitmap/geo/unknown) purple.
local KEY_HL = {
  string = "PosteRedisBrowserString",
  zset = "PosteRedisBrowserCollection",
  hash = "PosteRedisBrowserCollection",
  list = "PosteRedisBrowserCollection",
  set = "PosteRedisBrowserCollection",
  stream = "PosteRedisBrowserOther",
  bitmap = "PosteRedisBrowserOther",
  bitfield = "PosteRedisBrowserOther",
  bitfields = "PosteRedisBrowserOther",
  hyperloglog = "PosteRedisBrowserOther",
  hyperlonglong = "PosteRedisBrowserOther",
  geo = "PosteRedisBrowserOther",
}

local hl_ns = vim.api.nvim_create_namespace("poste_redis_browser")

-- Three header lines above the tree: line 1 = search bar, line 2 = db
-- select, line 3 = separator rule under the select. Every node line sits
-- below them; line math (append_children, apply_highlights,
-- get_node_at_line) offsets by this constant.
local HEADER_LINES = 3

M.HEADER_LINES = HEADER_LINES

--- Header lines rendered above the tree. Set by browser/init.lua:
---   [1] search bar, [2] db select, [3] separator.
M.header_lines = { "", "", "" }

--- When set, this node is the hidden display root: its own line is not
--- rendered; its children become the top level (depth 0). Used by the new
--- layout where the selected db lives in a header select bar, not the tree.
M.display_root = nil

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
    children = nil,        -- nil until scan_group loads it (lazy, M2+)
    expanded = false,
    loading = false,
    loaded = false,        -- true once its prefix has been SCAN'd
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
--- @return string[] lines, table[] node_map, number[] icon_cols
---   icon_cols[i] is the 0-based byte column of the ICON start for line i
---   (right after any marker glyph), computed here so apply_highlights never
---   re-reads the buffer.
function M.flatten_tree(nodes, depth, multi_select)
  depth = depth or 0
  local lines = {}
  local node_map = {}
  local icon_cols = {}

  for _, node in ipairs(nodes) do
    -- Hidden display root: emit no line, render its children at depth 0 so
    -- the tree top level is the selected db's groups/keys directly.
    if node == M.display_root then
      node._depth = -1
      if node.expanded and node.children then
        local child_lines, child_map, child_cols = M.flatten_tree(node.children, 0)
        node._desc_lines = #child_lines
        for _, cl in ipairs(child_lines) do table.insert(lines, cl) end
        for _, cn in ipairs(child_map) do table.insert(node_map, cn) end
        for _, cc in ipairs(child_cols) do table.insert(icon_cols, cc) end
      else
        node._desc_lines = 0
      end
    else
      local indent = string.rep("  ", depth)

      local icon
      if node.node_type == "key" then
        local t = node.meta and node.meta.type
        icon = (t and KEY_ICON[t]) or KEY_ICON.string
      else
        icon = ICON[node.node_type] or "  "
      end

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
      elseif node.node_type == "key" and node.meta and type(node.meta.type) == "string" then
        suffix = "  " .. node.meta.type
        if node.meta.size then suffix = suffix .. " (" .. node.meta.size .. ")" end
      end

      local line = indent .. marker .. icon .. " " .. node.name .. suffix
      table.insert(lines, line)
      table.insert(node_map, node)
      -- icon_col is the 0-based BYTE column of the icon start: indent bytes +
      -- marker bytes (a glyph + trailing space, or two spaces on a leaf).
      -- Computed here so apply_highlights never re-reads the buffer.
      node._icon_len = #icon
      local icon_col = #indent + #marker
      table.insert(icon_cols, icon_col)

      node._depth = depth
      if node.expanded and node.children then
        local child_lines, child_map, child_cols = M.flatten_tree(node.children, depth + 1)
        node._desc_lines = #child_lines
        for _, cl in ipairs(child_lines) do table.insert(lines, cl) end
        for _, cn in ipairs(child_map) do table.insert(node_map, cn) end
        for _, cc in ipairs(child_cols) do table.insert(icon_cols, cc) end
      else
        node._desc_lines = 0
      end
    end
  end

  return lines, node_map, icon_cols
end

--- Highlight one node's line. Columns come from flatten_tree (icon byte
--- start), so no buffer reads happen here.
--- @param buf number
--- @param line number 0-based buffer line
--- @param node table
--- @param icon_col number 0-based byte column of the icon start
local function highlight_line(buf, line, node, icon_col)
  -- Marker glyph sits right before the icon; color it gray. Leaf markers are
  -- two padding spaces — nothing to color there.
  local marker_len = 2
  if node.loading then
    marker_len = #MARKER_LOADING
  elseif node.expanded then
    marker_len = #MARKER_EXPANDED
  elseif node.node_type == "connection" or node.node_type == "db"
      or node.node_type == "group" then
    marker_len = #MARKER_COLLAPSED
  end
  if icon_col and icon_col > 0 and marker_len > 2 then
    vim.api.nvim_buf_add_highlight(buf, hl_ns, "PosteRedisBrowserMarker",
      line, icon_col - marker_len, icon_col)
  end

  local start = icon_col or 0
  local len = node._icon_len or 3
  local hl = "PosteRedisBrowserOther"
  if node.node_type == "connection" then
    hl = "PosteRedisBrowserConn"
  elseif node.node_type == "db" then
    hl = "PosteRedisBrowserDb"
  elseif node.node_type == "group" then
    hl = "PosteRedisBrowserGroup"
  elseif node.node_type == "key" then
    local t = node.meta and node.meta.type
    hl = (t and KEY_HL[t]) or "PosteRedisBrowserOther"
  end
  vim.api.nvim_buf_add_highlight(buf, hl_ns, hl, line, start, start + len)
end

--- Clear + re-apply browser highlights (marker + icon colors per node type).
--- Icon columns come from flatten_tree, so no buffer reads happen here.
--- @param buf number
--- @param line_to_node table[]
--- @param icon_cols number[]|nil parallel icon columns (from flatten_tree)
function M.apply_highlights(buf, line_to_node, icon_cols)
  vim.api.nvim_buf_clear_namespace(buf, hl_ns, 0, -1)
  for i, node in ipairs(line_to_node) do
    highlight_line(buf, i - 1 + HEADER_LINES, node, (icon_cols and icon_cols[i]) or 0)
  end
end

--- Write the flattened tree into the browser buffer, prepending the two
--- header lines (search bar + db select) from M.header_lines.
--- @param browser_buf number
--- @param line_to_node table[]  (in/out: replaced)
--- @param root_nodes table[]
--- @return table[] new line_to_node
function M.render_tree(browser_buf, line_to_node, root_nodes)
  if not browser_buf or not vim.api.nvim_buf_is_valid(browser_buf) then return line_to_node end

  local lines, node_map, icon_cols = M.flatten_tree(root_nodes)
  -- The search bar header line can legitimately be empty (query ""), so every
  -- header line is always written — skipping empties would drop the bar.
  for i = #M.header_lines, 1, -1 do
    table.insert(lines, 1, M.header_lines[i] or "")
  end
  vim.api.nvim_set_option_value("modifiable", true, { buf = browser_buf })
  vim.api.nvim_buf_set_lines(browser_buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = browser_buf })
  M.apply_highlights(browser_buf, node_map, icon_cols)
  return node_map
end

--- Replace only one header line without re-rendering the tree. Used while
--- typing in the search input or refreshing the db select.
--- @param buf number
--- @param text string
--- @param line number 1-based header line (1 = search, 2 = db select)
function M.set_header_line(buf, text, line)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  local idx = (line or 1) - 1
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, idx, idx + 1, false, { text })
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
end

----------------------------------------------------------------------
-- Search bar (header line 1): the icon is extmark virtual text, never
-- buffer text. The buffer line holds ONLY the query, so nothing typed
-- (or deleted) can ever merge the icon into a search. The icon is drawn
-- only in the idle/committed state — while editing it is removed so the
-- caret can never sit on or before it.
----------------------------------------------------------------------

local search_ns = vim.api.nvim_create_namespace("poste_redis_browser_search")

--- Fixed icon of the search bar: U+F002 (magnifying glass) + space. Rendered
--- as inline virt text ahead of the committed query (idle state only), so it
--- is never part of the input.
M.SEARCH_ICON = "\239\128\130"
M.SEARCH_PREFIX = M.SEARCH_ICON .. " "

--- Draw the search bar: the query as buffer text (the editable input). With
--- no query, a "filter by key" ghost hint follows the icon — all virt text,
--- so it can never be parsed (or edited) as a query.
--- @param buf number
--- @param query string committed search text ("" → show the hint)
function M.render_search_line(buf, query)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  M.set_header_line(buf, query or "", 1)
  M.decorate_search_line(buf, query or "", false)
end

--- Highlight the search bar. Idle state: the icon (+ optional ghost hint) as
--- inline virt text before the query, the query buffer text in
--- PosteRedisBrowserSearchText. While `editing` NOTHING is drawn — the icon
--- must not sit at the caret column, or the caret renders before it instead
--- of after the typed text.
--- @param buf number
--- @param query string
--- @param editing boolean true while the user is typing on the line
function M.decorate_search_line(buf, query, editing)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  vim.api.nvim_buf_clear_namespace(buf, search_ns, 0, -1)
  if editing then return end
  local virt = { { M.SEARCH_PREFIX, "PosteRedisBrowserSearchHint" } }
  if query == "" then
    virt[2] = { "filter by key", "PosteRedisBrowserSearchHint" }
  end
  vim.api.nvim_buf_set_extmark(buf, search_ns, 0, 0, {
    virt_text = virt,
    virt_text_pos = "inline",
    hl_mode = "combine",
  })
  if query ~= "" then
    vim.api.nvim_buf_add_highlight(buf, search_ns, "PosteRedisBrowserSearchText", 0, 0, -1)
  end
end

--- Drop the search bar's ghost hint + highlights (while the user is editing
--- the line, the hint must not sit in the way).
--- @param buf number
function M.clear_search_decoration(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  vim.api.nvim_buf_clear_namespace(buf, search_ns, 0, -1)
end

--- Incrementally append newly-loaded child nodes under a rendered node
--- WITHOUT re-flattening the whole tree. Inserts lines right after the
--- node's existing children and highlights only the new lines — O(delta),
--- not O(tree). Used by async's paced SCAN batches (P1-1).
---
--- Requires the node to already be in line_to_node (i.e. the tree was fully
--- rendered at least once). If it isn't, returns line_to_node unchanged and
--- the caller falls back to a full render.
--- @param buf number
--- @param line_to_node table[] (mutated: new nodes spliced in)
--- @param node table expanded non-leaf node whose children grew
--- @param new_nodes table[] nodes added since the last render
--- @return boolean true if appended; false/nil if node not rendered (caller
---   must fall back to a full render)
function M.append_children(buf, line_to_node, node, new_nodes)
  if not new_nodes or #new_nodes == 0 then return true end
  local node_idx
  if node == M.display_root then
    node_idx = 0  -- hidden root: children occupy the whole tree below headers
  else
    for i, n in ipairs(line_to_node) do
      if n == node then node_idx = i; break end
    end
  end
  if not node_idx then return false end  -- node not rendered → full render

  local child_depth = (node._depth or 0) + 1
  local lines, node_map, icon_cols = M.flatten_tree(new_nodes, child_depth)

  -- Buffer insert point (0-based): right after the node's rendered subtree.
  -- node_idx is a 1-based slot in line_to_node → buffer line node_idx+HEADER.
  local insert_0 = node_idx + HEADER_LINES + (node._desc_lines or 0)
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, insert_0, insert_0, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  -- Splice the new nodes into line_to_node at the matching 1-based slot.
  local pos = node_idx + (node._desc_lines or 0) + 1
  for k, n in ipairs(node_map) do
    table.insert(line_to_node, pos + k - 1, n)
  end

  -- Highlight only the new lines (existing highlights auto-shift on insert).
  for k, n in ipairs(node_map) do
    highlight_line(buf, insert_0 + k - 1, n, icon_cols[k])
  end
  node._desc_lines = (node._desc_lines or 0) + #lines
  return true
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
