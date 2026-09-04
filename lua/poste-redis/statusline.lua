--- Context statusline integration (poste-db statusline pattern).
--- Shows the context of the window under the cursor — connection (+ db when
--- known) — highlighted with the color configured for that connection:
---
---   [connections.local]
---   dialect = "redis"
---   url = "redis://127.0.0.1:6379/0"
---   color = "#98c379"   -- fg: hex, or a highlight-group name to link
---   link = "Statement"  -- optional: link instead of fg
---   bg = "#1b1f27"      -- optional background (hex or group name)
---
--- The context is window-scoped (poste-redis.context): a .redis buffer shows
--- its cursor's effective USE/SELECT context, the result panel shows the
--- active tab's origin context, everything else shows the global context.
--- Manual use: statusline = "%{lua:print('')}" style users can call
--- require("poste-redis.statusline").get_context() — it returns the context
--- with %#PosteRedisCtx<name># highlight markers, or "" when no context.
--- setup() additionally wires mini.statusline / lualine automatically.
local M = {}

local redis_state = require("poste-redis.state")

--- Context of the window under the cursor (window-scoped): the result panel
--- shows its active tab's context, a .redis file shows its USE/SELECT context
--- at the cursor, everything else shows the global context. See
--- `poste-redis.context`.
local function window_ctx()
  local ok, context = pcall(require, "poste-redis.context")
  if ok then return context.resolve() end
  return { connection = redis_state.context.connection, db = redis_state.context.db }
end

--- Build (once) + return the highlight group for a connection name, based
--- on its connections.toml entry (color / link / bg).
--- @param conn_name string
--- @return string|nil highlight group name
function M.get_ctx_color(conn_name)
  if not conn_name or conn_name == "" then return nil end
  local ok, connections = pcall(require, "poste-redis.connections")
  if not ok then return nil end
  local config = connections.get_connection_config(conn_name)
  if not config then return nil end

  local color = config.color
  local link = config.link
  local bg = config.bg
  if not color and not link then return nil end

  local hl_name = "PosteRedisCtx" .. conn_name:gsub("[^%w_]", "_")

  if link then
    pcall(vim.api.nvim_set_hl, 0, hl_name, { link = link })
    return hl_name
  end
  if not color then return nil end

  local hl_opts = {}
  if bg then
    if bg:sub(1, 1) == "#" then
      hl_opts.bg = bg
    else
      local bg_ok, bg_hl = pcall(vim.api.nvim_get_hl, 0, { name = bg })
      if bg_ok and bg_hl.bg then
        hl_opts.bg = bg_hl.bg
      else
        hl_opts.bg = bg
      end
    end
  end
  if color:sub(1, 1) == "#" then
    hl_opts.fg = color
  else
    -- a highlight-group name links through; anything else is a raw color
    local hl_exists = pcall(vim.api.nvim_get_hl, 0, { name = color })
    if hl_exists then
      hl_opts.link = color
    else
      hl_opts.fg = color
    end
  end
  local ok_hl = pcall(vim.api.nvim_set_hl, 0, hl_name, hl_opts)
  if not ok_hl then return nil end

  return hl_name
end

--- Resolve the window's context into display text ("local" / "local db3" /
--- "host db0" for raw URLs), or "" when no context applies. The result is
--- window-scoped, so the statusline always mirrors what that window is
--- about — a .redis buffer shows its cursor's effective USE/SELECT context,
--- the result panel shows the active tab's origin context.
--- @return string
function M.get_context_text()
  local ctx = window_ctx()
  local ok, context = pcall(require, "poste-redis.context")
  if ok then return context.display(ctx) end
  return ctx.connection or ""
end

--- Highlight group for the current window's context (nil → statusline
--- falls back).
--- @return string|nil
function M.get_context_hl()
  local ctx = window_ctx()
  if not ctx.connection then return nil end
  return M.get_ctx_color(ctx.connection)
end

--- Fully formatted context segment with %#/highlight# markers, or "".
--- @return string
function M.get_context()
  local ctx = M.get_context_text()
  if ctx == "" then return "" end
  local hl_name = M.get_context_hl()
  if hl_name then
    return "%#" .. hl_name .. "# " .. ctx .. " "
  end
  return " " .. ctx .. " "
end

local function fmt_ctx()
  return M.get_context()
end

--- Wire the context into mini.statusline / lualine when either is present.
--- Opt out with setup({ statusline = false }) from poste-redis setup opts.
function M.setup()
  vim.schedule(function()
    local ok_mini, statusline = pcall(require, "mini.statusline")
    if ok_mini then
      local orig_fileinfo = statusline.section_fileinfo
      statusline.section_fileinfo = function(...)
        local ctx = M.get_context_text()
        if ctx ~= "" then
          return fmt_ctx()
        end
        return orig_fileinfo(...)
      end

      statusline.config.content.active = function()
        local ctx = M.get_context_text()
        local ctx_hl = ctx ~= "" and M.get_context_hl() or nil

        local mode, mode_hl = statusline.section_mode({ trunc_width = 120 })
        local git = statusline.section_git({ trunc_width = 40 })
        local diff = statusline.section_diff({ trunc_width = 75 })
        local diagnostics = statusline.section_diagnostics({ trunc_width = 75 })
        local lsp = statusline.section_lsp({ trunc_width = 75 })
        local filename = statusline.section_filename({ trunc_width = 140 })
        local fileinfo = statusline.section_fileinfo({ trunc_width = 120 })
        local location = statusline.section_location({ trunc_width = 75 })
        local search = statusline.section_searchcount({ trunc_width = 75 })

        return statusline.combine_groups({
          { hl = mode_hl,                 strings = { mode } },
          { hl = "MiniStatuslineDevinfo", strings = { git, diff, diagnostics, lsp } },
          "%<",
          { hl = "MiniStatuslineFilename", strings = { filename } },
          "%=",
          { hl = ctx_hl or "MiniStatuslineFileinfo", strings = { fileinfo } },
          { hl = mode_hl,                 strings = { location } },
          { hl = "MiniStatuslineFileinfo", strings = { search } },
        })
      end
    end

    local ok_lualine, lualine = pcall(require, "lualine")
    if ok_lualine then
      local cfg = lualine.get_config()
      cfg.sections = cfg.sections or {}
      cfg.sections.lualine_c = cfg.sections.lualine_c or {}
      local component = { M.get_context_text, color = M.get_context_hl }
      local exists = false
      for _, comp in ipairs(cfg.sections.lualine_c) do
        if type(comp) == "table" and comp[1] == M.get_context_text then
          exists = true
          break
        end
      end
      if not exists then
        table.insert(cfg.sections.lualine_c, 1, component)
      end
      lualine.setup(cfg)
    end
  end)
end

return M
