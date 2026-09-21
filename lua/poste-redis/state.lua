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

--- Locate the `poste` binary. Same order as poste-db.nvim's copy of this
--- lookup: `vim.g.poste_binary`, then `$POSTE_BINARY`, then the configured
--- install path, then a dev build next to the plugin or in the CWD, then
--- `$PATH`.
---
--- The environment override exists because a config variable only reaches the
--- process that loaded the config: CI jobs and the busted child processes
--- plenary spawns for each spec file start without it, while the environment is
--- inherited.
---
--- This is the family's binary contract (see `poste.nvim/docs/schema.md`, Global
--- conventions): a candidate is usable only when it is both readable and
--- executable, and `install_binary.ensure()` asks this function instead of
--- repeating the walk -- a second copy there had already drifted once.
--- @return string|nil absolute path, or nil when no usable binary was found
--- @return string|nil which candidate answered, for `:PosteRedisInfo` and
---   checkhealth: five sources can win, and "why is my build not being used"
---   is only answerable if the winner is named.
function M.find_poste_binary()
  -- Readable is not enough: a downloaded/copied file without the exec bit (or
  -- a test dummy) would be picked over a working PATH entry and then fail at
  -- spawn with an opaque error.
  local function usable(p)
    return p ~= nil and p ~= "" and vim.fn.filereadable(p) == 1 and vim.fn.executable(p) == 1
  end
  -- An in-memory config value wins over the environment: the user set it for
  -- this session, while the variable may point at a build for other tooling.
  local g_val = vim.g.poste_binary
  if usable(g_val) then
    return vim.fn.fnamemodify(g_val, ":p"), "g:poste_binary"
  end
  if usable(vim.env.POSTE_BINARY) then
    return vim.fn.fnamemodify(vim.env.POSTE_BINARY, ":p"), "$POSTE_BINARY"
  end
  if M.config.poste_binary ~= "" and usable(M.config.poste_binary) then
    return vim.fn.fnamemodify(M.config.poste_binary, ":p"), "installed release"
  end
  local paths = {}
  local cwd = vim.fn.getcwd()
  if cwd ~= "" then
    table.insert(paths, { cwd .. "/target/debug/poste", "dev build in cwd" })
    table.insert(paths, { cwd .. "/target/release/poste", "dev build in cwd" })
  end
  local src = debug.getinfo(M.find_poste_binary, "S").source
  if src:sub(1, 1) == "@" then
    local dir = src:sub(2):match("^(.+/)lua/poste%-redis/") or ""
    if dir ~= "" then
      table.insert(paths, { dir .. "target/debug/poste", "dev build beside plugin" })
      table.insert(paths, { dir .. "target/release/poste", "dev build beside plugin" })
      table.insert(paths, { dir .. "bin/poste", "dev build beside plugin" })
    end
  end
  for _, cand in ipairs(paths) do
    if usable(cand[1]) then
      return vim.fn.fnamemodify(cand[1], ":p"), cand[2]
    end
  end
  local path = vim.fn.exepath("poste")
  if path ~= "" then return path, "$PATH" end
  return nil
end

--- `poste --version`, spawned without a shell: the binary path is user config
--- (`vim.g.poste_binary` / `$POSTE_BINARY`), and interpolating it into io.popen
--- would let a path with shell metacharacters run arbitrary commands. Same
--- rule as poste-db.nvim's copy.
--- @param binary string|nil defaults to find_poste_binary()
--- @return string|nil version text, or nil when the probe failed
function M.poste_version(binary)
  binary = binary or M.find_poste_binary()
  if not binary then return nil end
  local ok, obj = pcall(vim.system, { binary, "--version" }, { text = true, timeout = 5000 })
  if not ok or not obj then return nil end
  local result = obj:wait(5000)
  if not result or result.code ~= 0 or type(result.stdout) ~= "string" then return nil end
  local version = (result.stdout:gsub("%s+$", ""))
  return version ~= "" and version or nil
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
