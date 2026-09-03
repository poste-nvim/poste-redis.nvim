--- User commands for poste-redis.
local M = {}

function M.setup()
  vim.api.nvim_create_user_command("PosteRedisConnection", function()
    require("poste-redis.connections").select_connection()
  end, { desc = "Select a redis connection from connections.toml" })

  vim.api.nvim_create_user_command("PosteRedisChat", function()
    require("poste-redis.ai").open_chat()
  end, { desc = "Open the AI chat with the PosteRedis context (requires poste-ai.nvim)" })

  vim.api.nvim_create_user_command("PosteRedisContext", function()
    require("poste-redis.connections").select_context()
  end, { desc = "Select the redis connection used as the current context" })

  vim.api.nvim_create_user_command("PosteRedisRunFile", function(args)
    if args.args and args.args ~= "" then
      local fname = vim.fn.fnameescape(args.args)
      vim.cmd("edit " .. fname)
    end
    require("poste-redis.runner").run_file()
  end, { nargs = "?", complete = "file", desc = "Run the whole .redis file (honoring USE)" })

  vim.api.nvim_create_user_command("PosteRedisHistory", function()
    require("poste-redis.history").toggle()
  end, { desc = "Toggle the request history float" })

  vim.api.nvim_create_user_command("PosteRedisBrowser", function()
    require("poste-redis.browser.init").open()
  end, { desc = "Open the redis key browser" })

  vim.api.nvim_create_user_command("PosteRedisBrowserView", function(args)
    local browser = require("poste-redis.browser.init")
    if args.args and args.args ~= "" then
      browser.toggle_view(args.args)
    else
      browser.toggle_view()
    end
  end, {
    nargs = "?",
    complete = function() return { "flat", "flatten", "nested" } end,
    desc = "Toggle browser view; or set one: flat (no folders), flatten (方案A), nested (方案B)",
  })

  vim.api.nvim_create_user_command("PosteRedisInfo", function()
    local state = require("poste.state")
    local redis_state = require("poste-redis.state")
    local connections = require("poste-redis.connections")
    local util = require("poste-redis.util")
    local binary = state.find_poste_binary()
    local buf_name = vim.api.nvim_buf_get_name(0)
    local search_dir = buf_name ~= "" and vim.fn.fnamemodify(buf_name, ":h") or vim.fn.getcwd()
    local config_path = connections.find_connections_toml(search_dir)
    local parts = {
      "─",
      "poste_binary: " .. (binary or "not found"),
      "connection:  " .. tostring(redis_state.context.connection or "(none)"),
      "url:         " .. (redis_state.current_url and util.redact_url(redis_state.current_url) or "(none)"),
      "config:      " .. (config_path or ("not found (searched from " .. search_dir .. ")")),
      "─",
    }
    vim.notify(table.concat(parts, "\n"), vim.log.levels.INFO, { title = redis_state.TITLE })
  end, { desc = "Show poste-redis environment/connection info" })
end

return M
