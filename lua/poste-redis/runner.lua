--- Run orchestration: connect exec_run → result panel → history.
--- This is the <CR> / :PosteRedisRunFile entry point (poste-db's
--- sql_runner.run_sql_request equivalent).
local exec_run = require("poste-redis.exec_run")
local parser = require("poste-redis.parser")
local buffer = require("poste-redis.buffer")
local history = require("poste-redis.history")
local constants = require("poste-redis.constants")
local state = require("poste.state")
local redis_state = require("poste-redis.state")

local M = {}

--- Collect the panel's current rendered lines for the history snapshot.
local function buffer_lines()
  local b = buffer.buf()
  if b and vim.api.nvim_buf_is_valid(b) then
    return vim.api.nvim_buf_get_lines(b, 0, -1, false)
  end
  return {}
end

--- Render a batch of results into the panel and push one history entry.
--- @param results table[] result events
--- @param summaries table[] summary events
--- @param opts table { connection = string, src = number, batch_lines = number[] }
---   batch_lines: 0-based line numbers of every executed statement on src; one
---   result indicator is placed per line (index-aligned with results).
local function present(results, summaries, opts)
  opts = opts or {}
  -- Resolve the indicator target on the request buffer before the panel
  -- steals focus; looking up the current buffer after render targets signs
  -- at the result panel instead of the executed statement.
  local src = opts.src or vim.api.nvim_get_current_buf()
  local batch_lines = opts.batch_lines
  if not batch_lines or #batch_lines == 0 then
    local l = opts.line_0
    if l == nil then l = vim.fn.line(".") - 1 end
    batch_lines = l and { l } or {}
  end

  buffer.render(results, { render = true, connection = opts.connection })
  local first = results[1]
  local any_failed = false
  local total_latency = 0
  for _, ev in ipairs(results or {}) do
    if ev.status == "error" or ev.error then any_failed = true end
    total_latency = total_latency + (tonumber(ev.latency_ms) or 0)
  end
  history.push({
    command = first and first.command or "",
    connection = opts.connection or redis_state.context.connection,
    status = any_failed and "error" or (first and first.status or ""),
    latency_ms = total_latency,
    error = any_failed,
    lines = buffer_lines(),
  })
  -- indicator: replace each running spinner with the per-statement result icon
  -- on the request buffer's sign column (never inside the result panel). Every
  -- executed statement line from THIS run gets its own sign; anything left over
  -- was cleared at dispatch.
  local ok, indicators = pcall(require, "poste.indicators")
  if ok and src then
    for _, ev in ipairs(results or {}) do
      local line_0
      if type(ev.seq) == "number" then
        line_0 = batch_lines[ev.seq]
      elseif type(ev.start_line) == "number" then
        line_0 = ev.start_line - 1
      end
      if line_0 ~= nil then
        if ev.status == "error" or ev.error then
          indicators.set_indicator(src, line_0, "error")
        else
          indicators.set_indicator(src, line_0, "success")
        end
      end
    end
  end
end

--- Run the entry under the cursor, or the visual selection.
--- @param mode "cursor"|"visual"
--- @param range table|nil  { start_line, end_line } captured from the visual
---   selection while it was live; nil for cursor mode
function M.run_selection(mode, range)
  local src = vim.api.nvim_get_current_buf()
  local binary = state.find_poste_binary()
  if not binary then
    vim.notify("poste binary not found — build poste.nvim (cargo build --release)",
      vim.log.levels.ERROR, { title = constants.TITLE })
    return
  end
  if exec_run.is_busy() then
    vim.notify("A command is still running — press <Esc> to cancel first",
      vim.log.levels.WARN, { title = constants.TITLE })
    return
  end

  -- Every executed statement's start line (0-based) — the batch the sign
  -- column will track. The visual range is passed explicitly: it was captured
  -- by the keymap while the selection was live, before marks go stale.
  local entries
  if mode == "visual" then
    entries = parser.visual_entries(src, range)
  else
    local e = parser.cursor_entry(src)
    entries = e and { e } or {}
  end
  local batch_lines = {}
  for _, e in ipairs(entries) do
    if e.kind == "command" and e.start_line then
      batch_lines[#batch_lines + 1] = e.start_line - 1
    end
  end

  -- Context inheritance, symmetric with USE: a selection run spawns a fresh
  -- redis-exec connection (db 0), so the nearest SELECT above the selection
  -- is re-injected as the batch's first command — results then carry (and
  -- edit against) the db the file declared. Its indicator lands on the
  -- file's own SELECT line.
  if entries[1] and entries[1].start_line then
    local db, db_line = exec_run._db_for(src, entries[1].start_line)
    if db and db > 0 then
      local sel = parser.extract_entries(("SELECT %d\n"):format(db))[1]
      if sel then
        sel.start_line = db_line
        table.insert(entries, 1, sel)
        table.insert(batch_lines, 1, db_line - 1)
      end
    end
  end

  local ok, indicators = pcall(require, "poste.indicators")
  if ok then indicators.clear_all(src) end

  exec_run.run_selection_async(src, mode, { range = range, entries = entries }, {
    on_start = function(seq, _)
      local ok, indicators = pcall(require, "poste.indicators")
      if ok then
        for _, line_0 in ipairs(batch_lines) do
          indicators.set_indicator(src, line_0, "running")
        end
      end
    end,
    on_error = function(msg, _stderr)
      vim.notify(msg, vim.log.levels.ERROR, { title = constants.TITLE })
    end,
    on_done = function(results, summaries)
      local url, name = exec_run._connection_for(src)
      present(results, summaries, { connection = name or url, src = src, batch_lines = batch_lines })
    end,
  })
end

--- Run the whole file, honoring USE, rendering all results.
function M.run_file()
  local src = vim.api.nvim_get_current_buf()
  local binary = state.find_poste_binary()
  if not binary then
    vim.notify("poste binary not found — build poste.nvim (cargo build --release)",
      vim.log.levels.ERROR, { title = constants.TITLE })
    return
  end
  if exec_run.is_busy() then
    vim.notify("A command is still running — press <Esc> to cancel first",
      vim.log.levels.WARN, { title = constants.TITLE })
    return
  end

  local batch_lines = {}
  for _, e in ipairs(parser.buffer_entries(src)) do
    if e.kind == "command" and e.start_line then
      batch_lines[#batch_lines + 1] = e.start_line - 1
    end
  end

  local ok, indicators = pcall(require, "poste.indicators")
  if ok then
    indicators.clear_all(src)
    for _, line_0 in ipairs(batch_lines) do
      indicators.set_indicator(src, line_0, "running")
    end
  end

  local all_results = {}
  local last_conn_name = nil  -- last USE group's name (multi-USE files)
  exec_run.run_file_async(src, {}, {
    on_result = function(ev)
      all_results[#all_results + 1] = ev
    end,
    on_group = function(g)
      last_conn_name = g.connection_name or last_conn_name
    end,
    on_error = function(msg, _stderr)
      vim.notify(msg, vim.log.levels.ERROR, { title = constants.TITLE })
    end,
    on_done = function(results, summaries)
      local url, name = exec_run._connection_for(src)
      present(results, summaries, {
        connection = last_conn_name or name or url,
        src = src,
        batch_lines = batch_lines,
      })
    end,
  })
end

--- Run a single info-type command synchronously and notify the result.
--- @param entry table parser entry
--- @param opts table { connection = string }
function M.run_info(entry, opts)
  local ev, err = exec_run.run_sync(entry, opts)
  if not ev then
    vim.notify("Error: " .. tostring(err), vim.log.levels.ERROR, { title = constants.TITLE })
    return
  end
  local out = require("poste-redis.format").format_result(ev)
  vim.notify(table.concat(out.lines, "\n"), vim.log.levels.INFO, { title = constants.TITLE })
end

return M
