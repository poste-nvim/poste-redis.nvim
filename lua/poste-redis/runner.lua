--- Run orchestration: connect exec_run → result panel → history.
--- This is the <CR> / :PosteRedisRunFile entry point (poste-db's
--- sql_runner.run_sql_request equivalent).
local exec_run = require("poste-redis.exec_run")
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
--- @param opts table { connection = string, src = number, line_0 = number }
local function present(results, summaries, opts)
  opts = opts or {}
  -- Resolve the indicator target on the request buffer before the panel
  -- steals focus; looking up the current buffer after render targets signs
  -- at the result panel instead of the executed statement.
  local src = opts.src or vim.api.nvim_get_current_buf()
  local line_0 = opts.line_0
  if line_0 == nil then line_0 = vim.fn.line(".") - 1 end

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
  -- indicator: replace the running spinner with the result icon on the
  -- request line's sign column (never inside the result panel)
  local ok, indicators = pcall(require, "poste.indicators")
  if ok and src and line_0 then
    if any_failed then
      indicators.set_indicator(src, line_0, "error")
    else
      indicators.set_indicator(src, line_0, "success")
    end
  end
end

--- Run the entry under the cursor, or the visual selection.
--- @param mode "cursor"|"visual"
function M.run_selection(mode)
  local src = vim.api.nvim_get_current_buf()
  local start_line = vim.fn.line(".") - 1
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
  exec_run.run_selection_async(src, mode, {}, {
    on_start = function(seq, _)
      local ok, indicators = pcall(require, "poste.indicators")
      if ok then indicators.set_indicator(src, start_line, "running") end
    end,
    on_error = function(msg, _stderr)
      vim.notify(msg, vim.log.levels.ERROR, { title = constants.TITLE })
    end,
    on_done = function(results, summaries)
      local conn = exec_run._connection_for(src)
      present(results, summaries, { connection = conn, src = src, line_0 = start_line })
    end,
  })
end

--- Run the whole file, honoring USE, rendering all results.
function M.run_file()
  local src = vim.api.nvim_get_current_buf()
  local start_line = vim.fn.line(".") - 1
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
  local all_results = {}
  exec_run.run_file_async(src, {}, {
    on_result = function(ev)
      all_results[#all_results + 1] = ev
    end,
    on_error = function(msg, _stderr)
      vim.notify(msg, vim.log.levels.ERROR, { title = constants.TITLE })
    end,
    on_done = function(results, summaries)
      local conn = exec_run._connection_for(src)
      present(results, summaries, { connection = conn, src = src, line_0 = start_line })
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
