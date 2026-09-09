--- Redis key value viewer (M2, P1-3 full).
---
--- TYPE-first rendering with pagination for large collections:
---   hash → HSCAN cursor pages, set → SSCAN, zset → ZSCAN
---   list → LRANGE window pages, stream → XRANGE pages (exclusive last id)
---   string → GET (truncated at preview_max_bytes)
--- Each page renders as one tab in the result panel; <Tab>/<S-Tab> flip
--- pages. The page footer shows "loaded N / total M" when the count is
--- known. Truncated strings show the byte total and a load-full hint.
---
--- Runs on the persistent redis-session transport (session_conn): SELECT db
--- state is correct without touching the URL and the connection is reused
--- (P1-5). Async — the UI never blocks.

local session_conn = require("poste-redis.session_conn")
local buffer = require("poste-redis.buffer")
local format = require("poste-redis.format")
local redis_state = require("poste-redis.state")
local connections = require("poste-redis.connections")
local config = require("poste-redis.config")

local M = {}

--- View session state (one at a time; a new view replaces it).
local view = nil

--- Elements per value-viewer page (config.value_page_size). Deliberately
--- independent from scan_count, which paces the keyspace scan.
local function page_size()
  return config.config.value_page_size or 500
end

--- Build the per-page fetch command for a key/type/cursor.
--- @param key string
--- @param type string
--- @param cursor string|number|nil  SCAN cursor, or list start offset
--- @return string[]|nil command tokens
local function page_command(key, type, cursor)
  cursor = cursor or 0
  if type == "hash" then return { "HSCAN", key, tostring(cursor), "COUNT", tostring(page_size()) } end
  if type == "set" then return { "SSCAN", key, tostring(cursor), "COUNT", tostring(page_size()) } end
  if type == "zset" then return { "ZSCAN", key, tostring(cursor), "COUNT", tostring(page_size()) } end
  if type == "list" then
    local from = tonumber(cursor) or 0
    return { "LRANGE", key, tostring(from), tostring(from + page_size() - 1) }
  end
  if type == "stream" then
    local from = tostring(cursor)
    return { "XRANGE", key, from, "+", "COUNT", tostring(page_size()) }
  end
  if type == "string" then return { "GET", key } end
  return { "GET", key }  -- unknown: try the raw string
end

--- Resolve (key, conn_name, url, db) from a browser node.
--- @param node table
--- @return string|nil key, string|nil url, string|nil err, number db
local function resolve_node(node)
  local key = node.meta and node.meta.key
  local conn_name = node.meta and node.meta.connection
  if not key or not conn_name then
    return nil, nil, "Cannot resolve key", 0
  end
  local url = node.meta and node.meta.url
  local err
  if not url then
    url, err = connections.resolve(conn_name)
  end
  if not url then
    return nil, nil, "Connection '" .. conn_name .. "' not found: " .. tostring(err), 0
  end
  return key, url, nil, (node.meta and node.meta.db) or 0
end

--- Footer hint for the current page (loaded/total + full-load hint).
--- Appended by the caller to the page lines before add_page.
local function footer(loaded, total, opts)
  opts = opts or {}
  local parts = {}
  if total and total > 0 then
    parts[#parts + 1] = ("loaded %d / %d"):format(loaded, total)
  else
    parts[#parts + 1] = ("loaded %d"):format(loaded)
  end
  if opts.cursor and opts.cursor ~= "0" then
    parts[#parts + 1] = "· <Tab> next page"
  end
  if opts.truncated then
    parts[#parts + 1] = "· truncated — press K for raw JSON"
  end
  return "  (" .. table.concat(parts, "  ") .. ")"
end

--- Render one page event into the view's tab list and update the panel.
--- Bound to the owning view `v`, not the current global: a fetch from a
--- previously opened key can land after a new view replaced `view`, and
--- appending it to the new view's pages would mix two keys in one panel.
--- @param v table  the view this fetch belongs to
--- @param ev table result event
--- @param label string  tab title (page number / type)
local function add_page(v, ev, label)
  if view ~= v then return end
  local out = format.format_result(ev)
  out.meta.title = label
  out.meta.key = v.key
  out.meta.connection = v.conn_name
  out.meta.db = v.db
  -- the loaded/total footer: carried in meta for BOTH kinds; the text render
  -- appends it at display time, so tab.lines stays the pure value (yank / K
  -- never pick up the "(loaded N / total M …)" chrome)
  local f = footer(v.loaded, v.total, {
    cursor = v.cursor,
    truncated = (ev.value and ev.value.truncated) or false,
  })
  if f ~= "" then
    out.meta.footer = f
  end
  v.pages[#v.pages + 1] = out
  -- Re-render all pages as tabs (render_tabs replaces the tab set); the
  -- viewer stays on the newest page so a progressive <Tab> fetch advances
  -- to it instead of yanking the user back to page 1
  buffer.render_tabs(v.pages, { render = true, active = #v.pages })
  -- fire the one-shot first-render hook (tests / browser focus restore)
  if v.first_hook then
    local h = v.first_hook
    v.first_hook = nil
    pcall(h)
  end
end

--- Fetch and append the next page for the current view.
function M.next_page()
  if not view or view.done or view.busy then return end
  local v = view

  local cmd = page_command(v.key, v.type, v.cursor)
  if not cmd then return end
  v.busy = true

  local function on_event(ev)
    v.busy = false
    if v.type == "hash" then
      local entries = ev.value and ev.value.entries or {}
      v.cursor = (ev.value and ev.value.cursor) or "0"
      -- done is judged from the UPDATED cursor: the start cursor is "0" too,
      -- so checking before the update marked the view done after page 1 and
      -- a multi-page hash/set/zset could never load its next page
      if v.cursor == "0" then v.done = true end
      v.loaded = v.loaded + #entries
      v.total = ev.value and ev.value.len or nil
      add_page(v, ev, ("%s [hash · page %d]"):format(v.key, #v.pages + 1))
      -- the footer lives in meta; append the loaded/total line to the page
    elseif v.type == "set" or v.type == "zset" then
      local items = ev.value and ev.value.value or {}
      v.cursor = (ev.value and ev.value.cursor) or "0"
      if v.cursor == "0" then v.done = true end
      v.loaded = v.loaded + #items
      v.total = ev.value and ev.value.len or nil
      add_page(v, ev, ("%s [%s · page %d]"):format(v.key, v.type, #v.pages + 1))
    elseif v.type == "list" then
      local items = ev.value and ev.value.value or {}
      v.cursor = tostring((tonumber(v.cursor) or 0) + #items)
      v.loaded = v.loaded + #items
      if #items < page_size() then v.done = true end
      add_page(v, ev, ("%s [list · page %d]"):format(v.key, #v.pages + 1))
    elseif v.type == "stream" then
      -- XRANGE pages by exclusive last id (Redis 6.2 `(` prefix); an empty
      -- follow-up page (total was an exact page multiple) ends the view
      -- without appending an empty tab
      local items = ev.value and ev.value.value or {}
      v.loaded = v.loaded + #items
      if #items < page_size() then
        v.done = true
      else
        local last = items[#items]
        v.cursor = "(" .. (last and last.id or "0")
      end
      if #items > 0 or #v.pages == 0 then
        add_page(v, ev, ("%s [stream · page %d]"):format(v.key, #v.pages + 1))
      end
    elseif v.type == "string" then
      v.done = true
      add_page(v, ev, ("%s [string]"):format(v.key))
    else
      v.done = true
      add_page(v, ev, ("%s [%s]"):format(v.key, v.type))
    end
  end

  session_conn.execute(v.url, cmd, {
    on_response = on_event,
    on_error = function(msg)
      v.busy = false
      vim.notify("Value fetch failed: " .. tostring(msg), vim.log.levels.ERROR,
        { title = redis_state.TITLE })
    end,
  }, nil, { db = v.db, owner = "browser" })
end

--- Called after a panel tab switch: when the user lands on the value view's
--- LAST fetched page while the scan cursor is not exhausted, fetch the next
--- page — the footer's "<Tab> next page" contract. Without this the viewer
--- showed the hint but never had another page to switch to.
--- @param active_idx number  panel's active tab (1-based)
--- @param tab_count number  panel's total tabs
function M.maybe_fetch_next(active_idx, tab_count)
  if not view or view.done or view.busy then return end
  if active_idx ~= tab_count then return end
  M.next_page()
end

--- Load the full value of a truncated string (bypasses preview_max_bytes via
--- a large --max-bytes exec run, rendered as a fresh single tab). Async: the
--- run_sync version blocked the whole UI for the length of the fetch, so a
--- near-cap value froze Neovim on `F`. Both callbacks drop stale events (the
--- view may have been replaced mid-fetch) and clear the paging guard.
function M.load_full()
  if not view or view.type ~= "string" then return end
  local v = view
  local entry = {
    kind = "command",
    tokens = { "GET", v.key },
    raw = "GET " .. v.key,
  }
  -- exec path supports arbitrary --max-bytes; use a big cap for full load
  local exec_run = require("poste-redis.exec_run")
  v.busy = true  -- no interleaved <Tab> page fetch while the full load runs
  exec_run.run_async({ entry }, {
    connection = v.url,
    max_bytes = 1024 * 1024 * 64,  -- 64 MiB cap for "full"
  }, {
    on_result = function(ev)
      if view ~= v then return end
      v.busy = false
      local out = format.format_result(ev)
      out.meta.title = v.key .. " [string · full]"
      out.meta.key = v.key
      out.meta.connection = v.conn_name
      out.meta.db = v.db
      v.pages = { out }
      buffer.render_tabs(v.pages, { render = true })
    end,
    on_error = function(msg)
      if view ~= v then return end
      v.busy = false
      vim.notify("Full load failed: " .. tostring(msg), vim.log.levels.ERROR,
        { title = redis_state.TITLE })
    end,
  })
end

--- View a key's value in the result panel.
--- @param node table browser key node
--- @param root_nodes table[] unused (API parity with browser/init.lua)
--- @param render_hook fun()|nil called after the first page lands
function M.view(node, root_nodes, render_hook)
  local key, url, err, db = resolve_node(node)
  if not key or not url then
    vim.notify(err or "Cannot resolve key", vim.log.levels.ERROR, { title = redis_state.TITLE })
    return
  end
  local conn_name = node.meta and node.meta.connection
  local known_type = node.meta and node.meta.type

  local function start(t)
    view = {
      key = key, url = url, conn_name = conn_name, db = db,
      type = t or "unknown", cursor = "0", done = false, busy = false,
      loaded = 0, total = nil, pages = {},
      first_hook = render_hook,
    }
    -- panel tabs show the first page immediately; next/prev flip pages
    buffer.clear()
    M.next_page()
  end

  if known_type then
    start(known_type)
    return
  end

  -- TYPE first, then fetch by type
  session_conn.execute(url, { "TYPE", key }, {
    on_response = function(ev)
      start(ev.value and ev.value.value)
    end,
    on_error = function(msg)
      vim.notify("TYPE failed: " .. tostring(msg), vim.log.levels.ERROR,
        { title = redis_state.TITLE })
    end,
  }, nil, { db = db, owner = "browser" })
end

M._test = {
  page_command = page_command,
  footer = footer,
}

return M
