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
--- @param opts table { connection = string }
local function present(results, summaries, opts)
  buffer.render(results, { render = true })
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
  -- indicator: clear any running spinner (M1: no per-line spinner in panel)
  local src = vim.api.nvim_get_current_buf()
  local ok, indicators = pcall(require, "poste.indicators")
  if ok then
    if any_failed then
      indicators.set_indicator(src, vim.fn.line(".") - 1, "error")
    else
      indicators.set_indicator(src, vim.fn.line(".") - 1, "success")
    end
  end
end

--- Run the entry under the cursor, or the visual selection.
--- @param mode "cursor"|"visual"
function M.run_selection(mode)
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
  exec_run.run_selection_async(src, mode, {}, {
    on_start = function(seq, _)
      local ok, indicators = pcall(require, "poste.indicators")
      if ok then indicators.set_indicator(src, vim.fn.line(".") - 1, "running") end
    end,
    on_error = function(msg, _stderr)
      vim.notify(msg, vim.log.levels.ERROR, { title = constants.TITLE })
    end,
    on_done = function(results, summaries)
      local conn = exec_run._connection_for(src)
      present(results, summaries, { connection = conn })
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
      present(results, summaries, { connection = conn })
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
