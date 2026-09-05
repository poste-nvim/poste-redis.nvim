--- Actions for the "redis" AI context: confirm + execute an AI-authored
--- ```redis codeblock against the current context connection.
local constants = require("poste-redis.constants")
local redis_state = require("poste-redis.state")

local M = {}

--- Confirm gate for AI-authored redis commands. Commands on the dangerous
--- blacklist always ask (and say so); everything else runs silently.
--- @param code string  multi-line redis commands
--- @return boolean proceed
function M.confirm_redis(code)
  for _, line in ipairs(vim.split(code or "", "\n", { plain = true })) do
    local head = (line:match("^%s*(%S+)") or ""):upper()
    if head ~= "" and constants.is_dangerous_command(head) then
      local choice = vim.fn.confirm(
        ("AI wants to run a dangerous command (%s) — run it?"):format(head),
        "&Yes\n&No", 2, "Warning")
      if choice ~= 1 then return false end
    end
  end
  return true
end

--- Resolve the target connection URL: the current context connection.
--- @return string|nil url, string|nil err
function M.resolve_target()
  local connections = require("poste-redis.connections")
  local conn = redis_state.context.connection
  if not conn then
    return nil, "no redis context set — run :PosteRedisContext first"
  end
  return connections.resolve(conn)
end

--- Execute an AI-authored redis codeblock (one command per line) against the
--- current context connection. Results land in the result panel (the same
--- view as manual execution). Calls cb(ok) when finished — ok is false when
--- the run itself failed OR any command errored.
--- @param code string
--- @param refs table|nil  mention refs (unused; the context connection wins)
--- @param cb fun(ok: boolean)
function M.execute_redis(code, refs, cb)
  local url, err = M.resolve_target()
  if not url then
    vim.notify(err, vim.log.levels.ERROR, { title = redis_state.TITLE })
    cb(false)
    return
  end
  local src = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(src, 0, -1, false, vim.split(code or "", "\n", { plain = true }))
  -- on_error AND on_done can both fire for one run (run_async reports the
  -- process failure, then still reports done): the delete must be
  -- idempotent, and ok must reflect actual command failures
  local finished = false
  local function cleanup()
    if vim.api.nvim_buf_is_valid(src) then
      pcall(vim.api.nvim_buf_delete, src, { force = true })
    end
  end
  local exec_run = require("poste-redis.exec_run")
  exec_run.run_file_async(src, { connection = url }, {
    on_done = function(results)
      cleanup()
      if finished then return end
      finished = true
      local failed = false
      for _, ev in ipairs(results or {}) do
        if ev.status == "error" or ev.error then failed = true break end
      end
      cb(not failed)
    end,
    on_error = function()
      cleanup()
      if finished then return end
      finished = true
      cb(false)
    end,
  })
end

M._test = {
  resolve_target = M.resolve_target,
}

return M
