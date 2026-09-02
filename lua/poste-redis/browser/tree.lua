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

local config = require("poste-redis.config")

-- Nerd-font glyphs (no emoji): marker + icons per node type. Glyphs and the
-- per-type color map live in poste-redis.icons (shared with the result grid).
local MARKER_COLLAPSED = " "
local MARKER_EXPANDED = " "
local MARKER_LOADING = "… "

local icons = require("poste-redis.icons")
local ICON = icons.ICON
local KEY_ICON = icons.KEY_ICON
local KEY_HL = icons.KEY_HL

-- Highlight group per key type: collections orange, string green, everything
-- else (stream/bitmap/geo/unknown) purple. (map lives in poste-redis.icons)

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

--- Count a node plus all its descendants (for the truncation notice).
local function count_nodes(node)
  local n = 1
  for _, ch in ipairs(node.children or {}) do
    n = n + count_nodes(ch)
  end
  return n
end

--- Cap a node's rendered children at the per-node limit; returns the sliced
--- list and how many rows were hidden (surfaced as an inline notice).
local function cap_kids(kids)
  local per_node_cap = config.config.render_max_per_node
  if not per_node_cap or per_node_cap <= 0 or #kids <= per_node_cap then
    return kids, 0
  end
  local sliced = {}
  for i = 1, per_node_cap do sliced[i] = kids[i] end
  return sliced, #kids - per_node_cap
end

local function notice_node()
  return { node_type = "notice", name = "truncation notice", _icon_len = 0 }
end

--- Flatten a node list into display lines + a parallel node map.
--- Rendering is bounded twice: config.render_max_per_node children per node
--- (an inline "… N more" notice renders under the truncated node, so its
--- siblings stay reachable) and config.render_max_lines rows total (a
--- 100k-key tree flattened into buffer lines makes every full re-render a
--- huge rewrite, which starves the session's stdout processing — browser
--- freeze). Both cuts feed the skipped count the scans use to stop early.
--- @param nodes table[] root nodes
--- @param depth number internal
--- @param multi_select table|nil unused placeholder (redis browser has no
---   table multi-select yet; kept for tree.render parity)
--- @param budget number|nil remaining total row budget (nil = unlimited,
---   used by the incremental-append delta path)
--- @return string[] lines, table[] node_map, number[] icon_cols, number skipped
---   icon_cols[i] is the 0-based byte column of the ICON start for line i
---   (right after any marker glyph), computed here so apply_highlights never
---   re-reads the buffer. skipped = rows not rendered by per-node or total
---   caps (the scans stop paging once this is non-zero).
function M.flatten_tree(nodes, depth, multi_select, budget)
  depth = depth or 0
  local lines = {}
  local node_map = {}
  local icon_cols = {}
  local skipped = 0       -- per-node cap cuts (+ budget cuts, below)
  local budget_skipped = 0  -- rows cut by the total row budget

  local function emit(node_line, node, icon_col)
    table.insert(lines, node_line)
    table.insert(node_map, node)
    table.insert(icon_cols, icon_col)
  end

  local function emit_children(node, kids, child_depth)
    local child_lines, child_map, child_cols, child_skipped, child_budget = M.flatten_tree(
      kids, child_depth, nil, budget)
    skipped = skipped + child_skipped
    budget_skipped = budget_skipped + child_budget
    node._desc_lines = #child_lines
    for _, cl in ipairs(child_lines) do table.insert(lines, cl) end
    for _, cn in ipairs(child_map) do table.insert(node_map, cn) end
    for _, cc in ipairs(child_cols) do table.insert(icon_cols, cc) end
    return #child_lines
  end

  for _, node in ipairs(nodes) do
    -- Hidden display root: emit no node line, render its children at depth 0
    -- so the tree top level is the selected db's groups/keys directly. While
    -- it loads (or after a failed scan) one status line IS emitted — the db
    -- node has no row of its own, so without it a slow/failed scan would
    -- render as a silently blank tree.
    if node == M.display_root then
      node._depth = -1
      local status_lines, status_map, status_cols = {}, {}, {}
      if node.loading then
        node._icon_len = 0
        table.insert(status_lines, MARKER_LOADING .. "scanning keys…")
        table.insert(status_map, node)
        table.insert(status_cols, #MARKER_LOADING)
      elseif node.error then
        node._icon_len = 0
        node._err_s = 0
        node._err_e = #("scan failed: " .. tostring(node.error))
        table.insert(status_lines, "scan failed: " .. tostring(node.error))
        table.insert(status_map, node)
        table.insert(status_cols, 0)
      end
      node._desc_lines = #status_lines
      if node.expanded and node.children then
        local kids, hidden = cap_kids(node.children)
        skipped = skipped + hidden
        local rendered = emit_children(node, kids, 0)
        node._desc_lines = #status_lines + rendered
        if hidden > 0 then
          emit(("… %d more — use <leader>/ search to narrow"):format(hidden),
            notice_node(), 0)
          node._desc_lines = node._desc_lines + 1
        end
      end
      for i, cl in ipairs(status_lines) do
        emit(cl, status_map[i], status_cols[i])
      end
    else
      if budget == nil or budget > 0 then
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
        -- Failed scans on visible nodes (group/db/connection) surface inline —
        -- silent errors made every failure look like "the tree is broken".
        if node.error then
          node._err_s = #line
          line = line .. "  (error: " .. tostring(node.error) .. ")"
          node._err_e = #line
        end
        emit(line, node, #indent + #marker)
        node._icon_len = #icon

        node._depth = depth
        if budget then budget = budget - 1 end
        if node.expanded and node.children then
          local kids, hidden = cap_kids(node.children)
          skipped = skipped + hidden
          local rendered = emit_children(node, kids, depth + 1)
          node._desc_lines = rendered
          if hidden > 0 then
            emit(string.rep("  ", depth + 1)
              .. ("… %d more — use <leader>/ search to narrow"):format(hidden),
              notice_node(), 0)
            node._desc_lines = node._desc_lines + 1
          end
        else
          node._desc_lines = 0
        end
      else
        -- total budget exhausted: this node's whole subtree is not rendered
        local n = count_nodes(node)
        skipped = skipped + n
        budget_skipped = budget_skipped + n
      end
    end
  end

  return lines, node_map, icon_cols, skipped, budget_skipped
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

  if node._err_s and node._err_e and node._err_e > node._err_s then
    vim.api.nvim_buf_add_highlight(buf, hl_ns, "PosteRedisBrowserError",
      line, node._err_s, node._err_e)
  end
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

--- Rows dropped by the last render_tree (budget exhausted). The scan loops
--- read this to stop paging keys that would never render anyway.
M.last_truncated = 0

--- Write the flattened tree into the browser buffer, prepending the two
--- header lines (search bar + db select) from M.header_lines.
--- @param browser_buf number
--- @param line_to_node table[]  (in/out: replaced)
--- @param root_nodes table[]
--- @return table[] new line_to_node
function M.render_tree(browser_buf, line_to_node, root_nodes)
  if not browser_buf or not vim.api.nvim_buf_is_valid(browser_buf) then return line_to_node end

  local cap = config.config.render_max_lines
  local lines, node_map, icon_cols, skipped, budget_skipped = M.flatten_tree(root_nodes, 0, nil, cap)
  M.last_truncated = skipped or 0
  if (budget_skipped or 0) > 0 then
    -- per-node cuts render their notice inline; only a total-budget cut
    -- appends the trailing notice row
    local notice = notice_node()
    node_map[#node_map + 1] = notice
    icon_cols[#icon_cols + 1] = 0
    lines[#lines + 1] = ("  … %d more not rendered — use <leader>/ search to narrow"):format(budget_skipped)
  end
  -- The search bar header line can legitimately be empty (query ""), so every
  -- header line is always written — skipping empties would drop the bar.
  for i = #M.header_lines, 1, -1 do
    table.insert(lines, 1, M.header_lines[i] or "")
  end
  vim.api.nvim_set_option_value("modifiable", true, { buf = browser_buf })
  -- Explicit end index, NOT -1: nvim 0.12's delete-to-end path races job
  -- stdout processing during streamed scans (browser froze mid-scan; set_lines
  -- with an explicit end never reproduced it — 8/8 vs 2/4 drained runs).
  vim.api.nvim_buf_set_lines(browser_buf, 0, vim.api.nvim_buf_line_count(browser_buf), false, lines)
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
  -- Render cap: refuse to append past it — the caller falls back to a full
  -- render, which truncates and flags the scan to stop paging.
  local cap = config.config.render_max_lines
  if cap and cap > 0
      and (#line_to_node + #new_nodes > cap or (M.last_truncated or 0) > 0) then
    return false
  end
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
  -- Ancestors count these lines too: with two scans streaming at once (e.g.
  -- new db-level groups arriving while a group's keys append), the ancestor
  -- append computes its insert offset from ITS _desc_lines — leaving it
  -- stale splices buffer lines and line_to_node at the wrong place.
  local anc = node.parent
  while anc do
    anc._desc_lines = (anc._desc_lines or 0) + #lines
    anc = anc.parent
  end
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
