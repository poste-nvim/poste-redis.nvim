--- :checkhealth poste-redis — M1: nvim version, shared infra, binary with
--- redis-exec support, redis connections.toml section, tree-sitter (M2 note).
local M = {}

local start = vim.health.start or vim.health.report_start
local ok = vim.health.ok or vim.health.report_ok
local warn = vim.health.warn or vim.health.report_warn
local error = vim.health.error or vim.health.report_error

function M.check()
  start("poste-redis.nvim")

  -- Neovim version
  if vim.fn.has("nvim-0.10.0") == 1 then
    ok("Neovim >= 0.10.0")
  else
    error("Neovim >= 0.10.0 required (uses vim.system, vim.treesitter.language)")
  end

  -- Poste binary + redis-exec subcommand (vendored state, family
  -- dissolution: the binary is REQUIRED here — redis-exec is the transport)
  local state = require("poste-redis.state")
  local binary, source = state.find_poste_binary()
  if binary then
    -- The source is the actionable half: five candidates can win, and the
    -- installed release outranks a $PATH build the user expects to be used.
    ok("poste binary: " .. binary .. " (from " .. source .. ")")
    local version = state.poste_version(binary)
    if version then ok("poste version: " .. version) end
    -- Also shell-free, and it drops the `2>/dev/null` that only means something
    -- to a POSIX shell -- under Windows' cmd.exe it would have created a file.
    local help_ok, help = pcall(vim.system, { binary, "--help" }, { text = true, timeout = 5000 })
    local help_text = ""
    if help_ok then
      local result = help:wait(5000)
      help_text = result and (result.stdout or "") or ""
    end
    if help_text:match("redis%-exec") then
      ok("redis-exec subcommand available")
    else
      warn("redis-exec subcommand missing — rebuild poste.nvim: cargo build --release")
    end
  else
    error("poste binary not found — build poste.nvim (cargo build --release), or set vim.g.poste_binary / $POSTE_BINARY")
  end

  -- redis connections section
  local buf_name = vim.api.nvim_buf_get_name(0)
  local search_dir = buf_name ~= "" and vim.fn.fnamemodify(buf_name, ":h") or vim.fn.getcwd()
  local connections = require("poste-redis.connections")
  local config_path = connections.find_connections_toml(search_dir)
  if config_path then
    ok("connections.toml: " .. config_path)
    local redis_count = #connections.list_connections_sync(search_dir)
    if redis_count > 0 then
      ok(string.format("%d redis connection(s) found", redis_count))
    else
      warn("connections.toml has no redis sections (dialect = \"redis\")")
    end
  else
    warn("connections.toml not found (searched from " .. search_dir .. ")")
  end

  -- tree-sitter grammar (M2)
  local ts_ok = pcall(vim.treesitter.get_parser, 0, "poste_redis")
  if ts_ok then
    ok("tree-sitter poste_redis grammar active")
  else
    warn("tree-sitter poste_redis grammar not installed — regex syntax fallback active (M1)")
  end

  -- completion engine (P2-4)
  local blink_ok = pcall(require, "blink.cmp")
  if blink_ok then
    ok("blink.cmp loaded")
    local has_provider = false
    local cfg_ok, cfg = pcall(require, "blink.cmp.config")
    if cfg_ok and cfg.sources and cfg.sources.providers then
      has_provider = cfg.sources.providers["poste_redis"] ~= nil
    end
    if has_provider then
      ok("  poste_redis provider registered")
    else
      warn("  poste_redis provider not registered — completion may not work")
    end
  else
    local cmp_ok = pcall(require, "cmp")
    if cmp_ok then
      ok("nvim-cmp loaded")
    else
      warn("no completion engine (blink.cmp or nvim-cmp) — install blink.cmp for completion")
    end
  end
end

return M
