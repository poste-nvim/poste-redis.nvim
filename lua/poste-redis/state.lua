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

--- Whether this is Windows, where the executable found by the installer or by
--- cargo is always `poste.exe` and the bare name cannot be run. Derived the
--- same way as `install_binary.detect_platform()` (which is what decides the
--- written filename) so the two cannot disagree. A field, not a captured
--- local, so a spec can exercise the Windows branch off Windows. Same rule as
--- poste-db.nvim's copy.
M.is_windows = ((vim.loop.os_uname().sysname or ""):find("Windows", 1, true) ~= nil)

--- Resolve one candidate to the path that actually runs.
--- @param p string|nil
--- @return string|nil runnable path, nil when no form of it is usable
local function resolve_candidate(p)
  if p == nil or p == "" then return nil end
  -- Readable is not enough: a downloaded/copied file without the exec bit (or
  -- a test dummy) would be picked over a working PATH entry and then fail at
  -- spawn with an opaque error.
  local function usable(q)
    return vim.fn.filereadable(q) == 1 and vim.fn.executable(q) == 1
  end
  if usable(p) then return p end
  -- The candidates are all extension-less while on Windows that is one name
  -- away from the `poste.exe` the installer writes and cargo builds: matching
  -- only the bare name made this lookup miss the file startup had just
  -- downloaded, so it re-downloaded at every launch and checkhealth saw no
  -- binary. Either spelling also forgives a configured path without `.exe`.
  if M.is_windows then
    local exe = p .. ".exe"
    if usable(exe) then return exe end
  end
  return nil
end

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
--- executable, on Windows a candidate name also matches `<name>.exe`, and
--- `install_binary.ensure()` asks this function instead of repeating the walk
--- -- a second copy there had already drifted once.
--- @return string|nil absolute path, or nil when no usable binary was found
--- @return string|nil which candidate answered, for `:PosteRedisInfo` and
---   checkhealth: five sources can win, and "why is my build not being used"
---   is only answerable if the winner is named.
function M.find_poste_binary()
  -- An in-memory config value wins over the environment: the user set it for
  -- this session, while the variable may point at a build for other tooling.
  local run = resolve_candidate(vim.g.poste_binary)
  if run then
    return vim.fn.fnamemodify(run, ":p"), "g:poste_binary"
  end
  run = resolve_candidate(vim.env.POSTE_BINARY)
  if run then
    return vim.fn.fnamemodify(run, ":p"), "$POSTE_BINARY"
  end
  run = resolve_candidate(M.config.poste_binary)
  if run then
    return vim.fn.fnamemodify(run, ":p"), "installed release"
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
    run = resolve_candidate(cand[1])
    if run then
      return vim.fn.fnamemodify(run, ":p"), cand[2]
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
