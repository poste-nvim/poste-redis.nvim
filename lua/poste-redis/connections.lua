--- Redis connection management: parse `connections.toml` (redis 段), resolve
--- to a redis:// URL. The binary never reads config files — Lua resolves and
--- passes the URL (poste-redis EXECUTION-PLAN §5).
local state = require("poste-redis.state")
local redis_state = require("poste-redis.state")
local util = require("poste-redis.util")

local M = {}

-----------------------------------------------------------------------
-- Config file discovery
-----------------------------------------------------------------------

local _config_search_cache = {}
local _config_search_cache_mtime = {}

--- Walk up from `search_dir` to find connections.toml. The found path is
--- mtime-cached so a completion request costs one stat() instead of a
--- directory walk; a "not found" result is NEVER served stale — every miss
--- re-walks, so a file created mid-session is discovered by every caller
--- (resolve, listing, completion, browser), not only the picker paths that
--- also call invalidate(). mtime invalidation alone can't do this: it has no
--- answer for a file that did not exist when the cache was written (same
--- rule as poste-es connections.lua, and poste-db connections.lua).
--- @param search_dir string|nil
--- @return string|nil
function M.find_connections_toml(search_dir)
  search_dir = search_dir or vim.fn.getcwd()
  local cached = _config_search_cache[search_dir]
  if cached ~= nil and _config_search_cache_mtime[search_dir] == vim.fn.getftime(cached) then
    return cached
  end
  local result = util.find_file_upwards("connections.toml", search_dir)
  if not result then
    _config_search_cache[search_dir] = nil
    _config_search_cache_mtime[search_dir] = nil
    return nil
  end
  _config_search_cache[search_dir] = result
  _config_search_cache_mtime[search_dir] = vim.fn.getftime(result)
  return result
end

--- Drop the file-discovery caches. Negative walk-up results re-probe on
--- their own; this stays as the explicit re-probe hook for the pickers and
--- as a spec reset.
function M.invalidate()
  _config_search_cache = {}
  _config_search_cache_mtime = {}
end

--- Search dir for the current buffer (mirrors poste-db connections.lua).
--- @return string
local function get_search_dir()
  local buf_name = vim.api.nvim_buf_get_name(0)
  if buf_name ~= "" then
    return vim.fn.fnamemodify(buf_name, ":h")
  end
  return vim.fn.getcwd()
end

-----------------------------------------------------------------------
-- {{var}} expansion (OS env > .env > env.json), vendored-in-toml style
-----------------------------------------------------------------------

local _dotenv_cache = {}
local _dotenv_cache_mtime = {}

--- Parse dotenv content: KEY=VALUE, optional `export`, # comments,
--- single/double quoted values. Resolves {{VAR}} refs recursively.
--- @param content string
--- @param vars table<string,string>
--- @return table<string,string>
local function parse_dotenv(content, vars)
  vars = vars or {}
  for line in content:gmatch("[^\r\n]+") do
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
      local key, value = trimmed:match("^export%s+([%w_.]+)%s*=%s*(.-)%s*$")
      if not key then
        key, value = trimmed:match("^([%w_.]+)%s*=%s*(.-)%s*$")
      end
      if key then
        value = value:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
        vars[key] = value
      end
    end
  end
  for k, v in pairs(vars) do
    vars[k] = M.substitute_vars(v, vars)
  end
  return vars
end

--- Find and parse `.env` walking up from search_dir (mtime-cached).
--- A "not found" result is NEVER served stale — mtime has no answer for a
--- file that did not exist when the cache was written, so a `.env` created
--- mid-session would stay invisible forever (same rule as
--- find_connections_toml above, and the sticky not-found cache the mail
--- round fixed).
--- @param search_dir string
--- @return table<string,string>
local function load_dotenv(search_dir)
  local path = util.find_file_upwards(".env", search_dir)
  if not path then
    _dotenv_cache[search_dir] = nil
    _dotenv_cache_mtime[search_dir] = nil
    return {}
  end
  local mtime = vim.fn.getftime(path)
  if _dotenv_cache[search_dir] ~= nil and _dotenv_cache_mtime[search_dir] == mtime then
    return _dotenv_cache[search_dir]
  end
  local vars = {}
  local ok, data = pcall(vim.fn.readfile, path)
  if ok and data then
    vars = parse_dotenv(table.concat(data, "\n"), vars)
  end
  _dotenv_cache[search_dir] = vars
  _dotenv_cache_mtime[search_dir] = mtime
  return vars
end

--- Keep only scalar entries of an env section, as strings — the same rule as
--- the CLI's `scalar_vars` and poste-db's reader of the same name. A nested
--- object is structure, not a variable, and one reaching `gsub`'s replacement
--- raises "invalid replacement value (a table)" mid-resolution.
--- @param section table
--- @return table<string,string>
local function scalar_env_vars(section)
  local result = {}
  for k, v in pairs(section) do
    local t = type(v)
    if t == "string" then
      result[k] = v
    elseif t == "number" or t == "boolean" then
      result[k] = tostring(v)
    end
  end
  return result
end

--- Load env.json vars for the current env (matches Rust --env flow, incl. the
--- flat `{"KEY": "v"}` form the CLI resolves for every environment).
--- @param search_dir string
--- @return table<string,string>
local function load_env_json_vars(search_dir)
  local path = util.find_file_upwards("env.json", search_dir)
  if not path then return {} end
  local ok, data = pcall(vim.fn.readfile, path)
  if not ok or not data then return {} end
  local ok2, parsed = pcall(vim.json.decode, table.concat(data, "\n"))
  if not ok2 or type(parsed) ~= "table" then return {} end
  local envs = parsed.envs or parsed
  local section = envs[state.current_env or "dev"]
  if type(section) ~= "table" then section = envs end
  if type(section) ~= "table" then return {} end
  return scalar_env_vars(section)
end

--- Merge all env sources. Precedence: OS env > .env > env.json.
--- @param search_dir string
--- @return table<string,string>
function M.get_env_vars(search_dir)
  local vars = {}
  for k, v in pairs(load_env_json_vars(search_dir)) do vars[k] = v end
  for k, v in pairs(load_dotenv(search_dir)) do vars[k] = v end
  for k, v in pairs(vim.fn.environ()) do vars[k] = v end
  return vars
end

--- Substitute {{VAR}} refs (unknown kept literal, recursive, depth-capped).
--- @param s any
--- @param vars table<string,string>
--- @return any
function M.substitute_vars(s, vars, depth)
  if type(s) ~= "string" or not s:find("{{", 1, true) then
    return s
  end
  depth = depth or 0
  if depth >= 10 then return s end
  local result = (s:gsub("{{([%w_.]+)}}", function(name)
    return vars[name] or "{{" .. name .. "}}"
  end))
  if result:find("{{", 1, true) then
    return M.substitute_vars(result, vars, depth + 1)
  end
  return result
end

--- Resolve a config with {{VAR}} refs expanded.
--- @param conn table
--- @param vars table<string,string>
--- @return table
local function apply_env(conn, vars)
  local resolved = {}
  for k, v in pairs(conn) do
    resolved[k] = M.substitute_vars(v, vars)
  end
  return resolved
end

--- Percent-encode a URL component (RFC 3986 unreserved kept).
--- @param s any
--- @return any
local function percent_encode(s)
  if type(s) ~= "string" or s == "" then return s end
  return (s:gsub("[^%w%.%-%_%~]", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

-----------------------------------------------------------------------
-- Config parsing
-----------------------------------------------------------------------

local _config_cache = nil
local _config_cache_path = nil
local _config_cache_mtime = nil
local _config_cache_err = nil

--- Read + cache the connections.toml table (mtime invalidated).
--- @return table|nil, string|nil parsed, error
local function read_config(search_dir)
  local config_path = M.find_connections_toml(search_dir)
  if not config_path then return nil, "connections.toml not found" end
  local mtime = vim.fn.getftime(config_path)
  if _config_cache_path ~= config_path or _config_cache_mtime ~= mtime then
    local toml = require("poste-redis.toml")
    local parsed, err = toml.parse_file(config_path)
    -- The failure is cached under the same mtime key as the success: the
    -- statusline and completion read config on every redraw/keystroke, and a
    -- broken file would otherwise be re-read and re-parsed each time until it
    -- is fixed.
    _config_cache = parsed
    _config_cache_err = parsed and nil or err
    _config_cache_path = config_path
    _config_cache_mtime = mtime
  end
  if not _config_cache then return nil, _config_cache_err end
  return _config_cache, nil
end

--- Get the (env-resolved) config for a named connection.
--- @param name string
--- @return table|nil
function M.get_connection_config(name)
  local parsed, err = read_config(get_search_dir())
  if not parsed then return nil, err end
  local conn = parsed[name]
  if not conn then return nil, "Connection '" .. name .. "' not found" end
  return apply_env(conn, M.get_env_vars(get_search_dir()))
end

--- Build a redis:// URL from individual fields (url absent).
--- Returns nil, err when the connection isn't a redis one or is malformed.
--- @param conn table env-resolved connection config
--- @param name? string connection name, for the error text
--- @return string|nil, string|nil
local function build_url_from_fields(conn, name)
  local scheme = conn.tls and "rediss" or "redis"
  local host = conn.host
  if not host or host == "" then
    return nil, "Missing host for redis connection"
  end
  -- Which connection, so a shared file with ten of them stays diagnosable.
  -- The bad value itself is NOT echoed: `port = "{{REDIS_PASS}}"` (a typo in
  -- the var name) would otherwise print a secret that resolved.
  local at = name and (" (connection '%s')"):format(name) or ""
  local function field(label, value, default, min, max)
    if value == nil or value == "" then return default, nil end
    local n = tonumber(value)
    if not n or n % 1 ~= 0 or n < min or (max and n > max) then
      return nil, ("Invalid %s for redis connection%s: expected an integer %s"):format(
        label, at, max and ("from " .. min .. " to " .. max) or ("of " .. min .. " or more"))
    end
    return n, nil
  end
  -- `port` is bounded by the 16-bit transport and 0 is not a socket port —
  -- the same 1..65535 rule both SQL mirrors apply to their `port` field.
  -- `db` has no upper bound (maxmemory-databases is a server setting, and
  -- `SELECT` is where an out-of-range index surfaces) but 0 is a real index.
  local port, port_err = field("port", conn.port, 6379, 1, 65535)
  if port_err then return nil, port_err end
  local db, db_err = field("db", conn.db, 0, 0)
  if db_err then return nil, db_err end
  local auth = ""
  if conn.username and conn.password then
    auth = percent_encode(conn.username) .. ":" .. percent_encode(conn.password) .. "@"
  elseif conn.password then
    auth = ":" .. percent_encode(conn.password) .. "@"
  elseif conn.username then
    auth = percent_encode(conn.username) .. "@"
  end
  return string.format("%s://%s%s:%d/%d", scheme, auth, host, port, db)
end

--- Resolve a connection name to a redis:// URL.
--- URL field wins when present; otherwise fields are joined. Validates scheme.
--- @param name string
--- @param opts? table { search_dir = string|nil }
--- @return string|nil, string|nil url, error_message
function M.resolve_redis_url(name, opts)
  opts = opts or {}
  local search_dir = opts.search_dir or get_search_dir()
  local parsed, err = read_config(search_dir)
  if not parsed then
    return nil, err or "connections.toml not found (searched from " .. search_dir .. ")"
  end
  local conn = parsed[name]
  if not conn then return nil, "Connection '" .. name .. "' not found in connections.toml" end
  conn = apply_env(conn, M.get_env_vars(search_dir))
  if conn.dialect ~= "redis" then
    return nil, ("Connection '%s' is not a redis connection (dialect=%s)"):format(
      name, conn.dialect or "(unset) — set dialect = \"redis\"")
  end
  if conn.url and conn.url ~= "" then
    if not (conn.url:sub(1, 8) == "redis://" or conn.url:sub(1, 9) == "rediss://") then
      return nil, "URL for '" .. name .. "' must start with redis:// or rediss://"
    end
    return conn.url, nil
  end
  return build_url_from_fields(conn, name)
end

--- Resolve a connection REFERENCE that may be a connections.toml name or an
--- already-formed redis URL: URLs pass through untouched, names go through
--- resolve_redis_url. The one funnel for "connection field → URL" — the
--- result panel, grid editing, and browser actions each used to roll their
--- own (and drift).
--- @param name_or_url string|nil
--- @return string|nil url, string|nil err
function M.resolve(name_or_url)
  if not name_or_url or name_or_url == "" then
    return nil, "no connection given"
  end
  if name_or_url:sub(1, 8) == "redis://" or name_or_url:sub(1, 9) == "rediss://" then
    return name_or_url, nil
  end
  return M.resolve_redis_url(name_or_url)
end

--- Sync list of redis connections: { { name, url, host, port, db }, ... }.
--- Public so health.lua and completion don't reach through `_test`.
--- @param search_dir string|nil
--- @return table[]
function M.list_connections_sync(search_dir)
  search_dir = search_dir or get_search_dir()
  local parsed, _ = read_config(search_dir)
  local list = {}
  if parsed then
    local vars = M.get_env_vars(search_dir)
    for name, conn in pairs(parsed) do
      local resolved = apply_env(conn, vars)
      if resolved.dialect ~= "redis" then goto continue end
      local url
      if resolved.url and resolved.url ~= "" then
        if resolved.url:sub(1, 8) == "redis://" or resolved.url:sub(1, 9) == "rediss://" then
          url = resolved.url
        end
      else
        url = build_url_from_fields(resolved, name)
      end
      local host = resolved.host
      if not host and url then
        -- URL-derived host for display: strip the userinfo FIRST, or the
        -- capture grabs `user:password` whole (credentials must never land
        -- in a host field, even one nothing renders today)
        local no_userinfo = url:gsub("//([^/@]+)@", "//")
        host = no_userinfo:match("^rediss?://([^:/]+)")
      end
      local db = resolved.db
      if not db and url then db = url:match("/(%d+)$") end
      table.insert(list, {
        name = name,
        dialect = resolved.dialect,
        url = url,
        host = host,
        port = resolved.port,
        db = db,
      })
      ::continue::
    end
  end
  return list
end

--- Async list (callback variant of list_connections_sync).
function M.list_connections(callback, opts)
  local search_dir = (opts and opts.search_dir) or get_search_dir()
  local list = M.list_connections_sync(search_dir)
  vim.schedule(function() callback(list) end)
end

--- Sorted redis connection names (completion / picker hints). Sync.
--- @param search_dir string|nil
--- @return string[]
function M.redis_connection_names(search_dir)
  local list = M.list_connections_sync(search_dir)
  local names = {}
  for _, c in ipairs(list) do
    names[#names + 1] = c.name
  end
  table.sort(names)
  return names
end

--- Set the current connection context (from USE directive or selector).
--- @param name string
--- @param url string
function M.apply_connection(name, url)
  redis_state.context.connection = name
  redis_state.context.db = nil
  redis_state.current_url = url
end

--- Resolve + apply a connection name as the current context.
--- @param name string
--- @return boolean ok, string|nil error
function M.use_connection(name)
  local url, err = M.resolve_redis_url(name)
  if not url then return false, err end
  M.apply_connection(name, url)
  return true, nil
end

--- Open the connection picker (poste.select); on selection, applies the
--- connection as the current context and notifies.
function M.select_connection()
  local redis_util = require("poste-redis.util")
  M.invalidate()  -- re-probe: the file may exist by now even if cached "not found"
  M.list_connections(function(list)
    if #list == 0 then
      vim.notify("No redis connections found in connections.toml",
        vim.log.levels.WARN, { title = redis_state.TITLE })
      return
    end
    local items = {}
    for _, c in ipairs(list) do
      items[#items + 1] = string.format("%s  %s", c.name, redis_util.redact_url(c.url or ""))
    end
    -- vendored picker (family dissolution): the module is bundled, so the
    -- old "poste.select unavailable" pcall guard is gone
    local select_mod = require("poste-redis.select")
    select_mod.select(items, "Select Redis Connection", function(selected)
      if not selected then return end
      for _, c in ipairs(list) do
        if string.format("%s  %s", c.name, redis_util.redact_url(c.url or "")) == selected then
          M.apply_connection(c.name, c.url)
          vim.notify("Redis connection: " .. c.name, vim.log.levels.INFO, { title = redis_state.TITLE })
          -- the open browser follows the new context immediately (no picker)
          pcall(function()
            require("poste-redis.browser.init").open({
              source_buf = vim.api.nvim_get_current_buf(),
              connection = { name = c.name, url = c.url },
            })
          end)
          break
        end
      end
    end)
  end)
end

--- Open the context picker: pick a connection, make it the current context
--- (all later queries run against it) and notify with its configured color.
function M.select_context()
  local redis_util = require("poste-redis.util")
  local statusline = require("poste-redis.statusline")
  M.invalidate()  -- re-probe: the file may exist by now even if cached "not found"
  M.list_connections(function(list)
    if #list == 0 then
      vim.notify("No redis connections found in connections.toml",
        vim.log.levels.WARN, { title = redis_state.TITLE })
      return
    end
    local items = {}
    for _, c in ipairs(list) do
      items[#items + 1] = string.format("%s  %s", c.name, redis_util.redact_url(c.url or ""))
    end
    -- vendored picker (family dissolution): the module is bundled, so the
    -- old "poste.select unavailable" pcall guard is gone
    local select_mod = require("poste-redis.select")
    select_mod.select(items, "Select Redis Context", function(selected)
      if not selected then return end
      for _, c in ipairs(list) do
        if string.format("%s  %s", c.name, redis_util.redact_url(c.url or "")) == selected then
          local use_ok, use_err = M.use_connection(c.name)
          if not use_ok then
            vim.notify("Context switch failed: " .. tostring(use_err),
              vim.log.levels.ERROR, { title = redis_state.TITLE })
            return
          end
          local hl = statusline.get_ctx_color(c.name)
          vim.notify(("Context: %s%s"):format(c.name,
            hl and (" (%s)"):format(hl) or ""),
            vim.log.levels.INFO, { title = redis_state.TITLE })
          pcall(function()
            require("poste-redis.browser.init").open({
              source_buf = vim.api.nvim_get_current_buf(),
              connection = { name = c.name, url = c.url },
            })
          end)
          break
        end
      end
    end)
  end)
end

M._test = {
  get_search_dir = get_search_dir,
  build_url_from_fields = build_url_from_fields,
  parse_dotenv = parse_dotenv,
  apply_env = apply_env,
  percent_encode = percent_encode,
  --- Drop every file/mtimes cache (specs use temp dirs).
  reset_caches = function()
    _config_search_cache = {}
    _config_search_cache_mtime = {}
    _config_cache = nil
    _config_cache_path = nil
    _config_cache_mtime = nil
    _config_cache_err = nil
    _dotenv_cache = {}
    _dotenv_cache_mtime = {}
  end,
}

return M
