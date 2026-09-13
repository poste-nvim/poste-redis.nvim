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
---
--- Self-contained since the poste.nvim family dissolution (no shared
--- compose layer): this module wires mini.statusline itself with a strict
--- scope-guard — it renders only on windows redis owns (result panel, key
--- browser, .redis source buffer with a resolvable connection) and falls
--- through to the captured original everywhere else, so sibling plugins
--- wrapping the same hooks chain instead of fighting over the global slots.
--- The old global fallback ("show the session context on any buffer") is
--- deliberately NOT rendered by the mini wiring.
local M = {}

local redis_state = require("poste-redis.state")

--- Context of the window under the cursor (window-scoped): the result panel
--- shows its active tab's context, a .redis file shows its USE/SELECT context
--- at the cursor, everything else shows the global context. See
--- `poste-redis.context`.
local function window_ctx(win)
  local ok, context = pcall(require, "poste-redis.context")
  if ok then return context.resolve(win) end
  return { connection = redis_state.context.connection, db = redis_state.context.db }
end

local hl_cache = {}      -- conn_name -> { hl_name = string, fp = string }
local hl_cache_group = nil

--- get_ctx_color runs on EVERY statusline evaluation and every cursor move
--- (source winbar + browser winbar). nvim_set_hl invalidates global
--- highlighting and forces a full-screen redraw even when the value is
--- unchanged, so the definition is only re-applied when the connections.toml
--- fingerprint (color/link/bg) actually changed; a ColorScheme event drops
--- the cache so definitions re-derive against the new scheme.
local function cache_drop_group()
  if not hl_cache_group then
    hl_cache_group = vim.api.nvim_create_augroup("PosteRedisCtxHlCache", { clear = true })
    vim.api.nvim_create_autocmd("ColorScheme", {
      group = hl_cache_group,
      callback = function() hl_cache = {} end,
    })
  end
end

--- Build (once per fingerprint) + return the highlight group for a connection
--- name, based on its connections.toml entry (color / link / bg).
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

  local fp = (color or "") .. "\0" .. (link or "") .. "\0" .. (bg or "")
  local cached = hl_cache[conn_name]
  if cached and cached.fp == fp then return cached.hl_name end

  local hl_name = "PosteRedisCtx" .. conn_name:gsub("[^%w_]", "_")

  if link then
    pcall(vim.api.nvim_set_hl, 0, hl_name, { link = link })
    cache_drop_group()
    hl_cache[conn_name] = { hl_name = hl_name, fp = fp }
    return hl_name
  end
  if not color then return nil end

  local hl_opts = {}
  if bg then
    if bg:sub(1, 1) == "#" then
      hl_opts.bg = bg
    elseif vim.fn.hlexists(bg) == 1 then
      local bg_ok, bg_hl = pcall(vim.api.nvim_get_hl, 0, { name = bg })
      if bg_ok and bg_hl.bg then
        hl_opts.bg = bg_hl.bg
      end
    end
    -- an unknown bg name is dropped, not passed through: nvim_set_hl would
    -- reject the whole definition and the connection loses its fg color too
  end
  if color:sub(1, 1) == "#" then
    hl_opts.fg = color
  elseif vim.fn.hlexists(color) == 1 then
    -- a highlight-group name links through
    hl_opts.link = color
  else
    hl_opts.fg = color
  end
  local ok_hl = pcall(vim.api.nvim_set_hl, 0, hl_name, hl_opts)
  if not ok_hl then return nil end

  cache_drop_group()
  hl_cache[conn_name] = { hl_name = hl_name, fp = fp }
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

-- `%` is the statusline escape character: a connection named "100%" baked
-- in raw makes every statusline redraw fail with E539. Doubling it renders
-- a literal `%` (hl names are already sanitized to [%w_]).
local function escape_statusline(s)
  return (s:gsub("%%", "%%%%"))
end

--- Fully formatted context segment with %#/highlight# markers, or "".
--- @return string
function M.get_context()
  local ctx = M.get_context_text()
  if ctx == "" then return "" end
  local hl_name = M.get_context_hl()
  if hl_name then
    return "%#" .. hl_name .. "# " .. escape_statusline(ctx) .. " "
  end
  return " " .. escape_statusline(ctx) .. " "
end

local function fmt_ctx()
  return M.get_context()
end

--- Does redis own the current window? True only when resolve_scoped names a
--- connection on a NON-global branch: the result panel, the key browser, or
--- a .redis source buffer whose USE/SELECT context resolves. The global
--- session fallback must NOT claim arbitrary buffers (family scope
--- discipline — 3.4 of the dissolution handoff): a plain buffer falls
--- through to whatever sibling wrapper was captured before ours.
local function owns_window()
  local ok, context = pcall(require, "poste-redis.context")
  if not ok then return false end
  local ok_res, ctx = pcall(context.resolve_scoped)
  if not ok_res or not ctx or not ctx.connection then return false end
  return ctx.branch ~= "global"
end

--- mini.statusline wiring. Scope-guarded (see owns_window); both wrappers
--- fall through to the captured original on windows redis does not own, so
--- plugins that wrap the same hooks stay chained. The
--- `vim.g.poste_redis_statusline_wired` flag keeps a module reload from
--- re-capturing the already-wrapped hooks (wrapper stacking).
local function wire_mini_statusline()
  vim.schedule(function()
    local ok_mini, statusline = pcall(require, "mini.statusline")
    if not ok_mini then return end
    if vim.g.poste_redis_statusline_wired then return end
    vim.g.poste_redis_statusline_wired = true

    local orig_fileinfo = statusline.section_fileinfo
    statusline.section_fileinfo = function(...)
      if owns_window() then
        -- Bake the per-connection highlight into the returned string itself:
        -- another plugin may own `content.active`, but `%#…#` markup inside
        -- the string survives any layout.
        return fmt_ctx()
      end
      return orig_fileinfo(...)
    end

    local orig_active = statusline.config.content.active
    statusline.config.content.active = function()
      if not owns_window() then
        -- Not a redis window: fall through so an earlier sibling wrapper
        -- still renders its context (chain discipline).
        if orig_active then return orig_active() end
        return ""
      end
      local ctx_hl = M.get_context_hl()

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
  end)
end

--- Wire mini.statusline (scope-guarded, above) and lualine. The lualine
--- component keeps its pre-dissolution behaviour: it shows the active
--- window's context (including the global session fallback) in lualine's
--- own namespaced component, which is not part of the mini.statusline
--- chain and never blocked a sibling.
local function setup_lualine()
  vim.schedule(function()
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

function M.setup()
  wire_mini_statusline()
  setup_lualine()
end

return M
