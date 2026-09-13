--- Redis-specific state (isolated from SQL/HTTP).
--- Loaded by poste-redis.nvim plugin; referenced via require("poste-redis.state").
---
--- Since the poste.nvim family dissolution this module also hosts the
--- former shared `poste.state` surface (config singleton, binary
--- resolution, highlight overrides, log) — merged from
--- poste.nvim@5b3759e lua/poste/state.lua.
local M = {}

M.TITLE = "PosteRedis"

M.context = {
  connection = nil,   -- current connection name (from USE directive / selector)
  db = nil,           -- current SELECT db (0 if unset)
}
M.last_response = nil  -- last parsed exec summary/result for statusline (M2)

--- Current connection URL resolved for the active context (password redacted
--- never persisted — lives only in memory).
M.current_url = nil

M.config = {
  poste_binary = vim.fn.stdpath("data") .. "/poste/bin/poste",
  log_file = vim.fn.stdpath("cache") .. "/poste-redis.log",
  highlights = {},
}

M.current_env = "dev"

function M.find_poste_binary()
  local g_val = vim.g.poste_binary
  if g_val and g_val ~= "" and vim.fn.filereadable(g_val) == 1 then
    return vim.fn.fnamemodify(g_val, ":p")
  end
  if M.config.poste_binary ~= "" and vim.fn.filereadable(M.config.poste_binary) == 1 then
    return vim.fn.fnamemodify(M.config.poste_binary, ":p")
  end
  local paths = {}
  local cwd = vim.fn.getcwd()
  if cwd ~= "" then
    table.insert(paths, cwd .. "/target/debug/poste")
    table.insert(paths, cwd .. "/target/release/poste")
  end
  local src = debug.getinfo(M.find_poste_binary, "S").source
  if src:sub(1, 1) == "@" then
    local dir = src:sub(2):match("^(.+/)lua/poste%-redis/") or ""
    if dir ~= "" then
      table.insert(paths, dir .. "target/debug/poste")
      table.insert(paths, dir .. "target/release/poste")
      table.insert(paths, dir .. "bin/poste")
    end
  end
  for _, p in ipairs(paths) do
    if vim.fn.filereadable(p) == 1 then return vim.fn.fnamemodify(p, ":p") end
  end
  local path = vim.fn.exepath("poste")
  return path ~= "" and path or nil
end

function M.apply_highlight_overrides(group_names)
  local overrides = M.config.highlights
  if not overrides or vim.tbl_isempty(overrides) then return end
  for _, name in ipairs(group_names) do
    local attr = overrides[name]
    if attr then
      vim.api.nvim_set_hl(0, name, attr)
    end
  end
end

function M.log(level, msg)
  if not M.config.log_file or M.config.log_file == "" then return end
  local ts = os.date("%Y-%m-%d %H:%M:%S")
  local line = string.format("[%s] [%s] %s\n", ts, level, msg)
  local f = io.open(M.config.log_file, "a")
  if f then
    f:write(line)
    f:close()
  end
end

return M
