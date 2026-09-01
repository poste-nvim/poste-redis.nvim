--- Redis connection management: parse `connections.toml` (redis 段), resolve
--- to a redis:// URL. The binary never reads config files — Lua resolves and
--- passes the URL (poste-redis EXECUTION-PLAN §5).
local state = require("poste.state")
local redis_state = require("poste-redis.state")
local util = require("poste.util")

local M = {}

-----------------------------------------------------------------------
-- Config file discovery
-----------------------------------------------------------------------

local _config_search_cache = {}
local _config_search_cache_mtime = {}

--- Walk up from `search_dir` to find connections.toml (mtime-cached).
--- @param search_dir string|nil
--- @return string|nil
function M.find_connections_toml(search_dir)
  search_dir = search_dir or vim.fn.getcwd()
  if _config_search_cache[search_dir] ~= nil then
    local cached = _config_search_cache[search_dir]
    if cached == false then return nil end
    local mtime = vim.fn.getftime(cached)
    if _config_search_cache_mtime[search_dir] == mtime then
      return cached
    end
  end
  local result = util.find_file_upwards("connections.toml", search_dir)
  _config_search_cache[search_dir] = result or false
  _config_search_cache_mtime[search_dir] = result and vim.fn.getftime(result) or nil
  return result
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
--- @param search_dir string
--- @return table<string,string>
local function load_dotenv(search_dir)
  local path = util.find_file_upwards(".env", search_dir)
  local mtime = path and vim.fn.getftime(path) or nil
  if _dotenv_cache[search_dir] ~= nil and _dotenv_cache_mtime[search_dir] == mtime then
    return _dotenv_cache[search_dir]
  end
  local vars = {}
  if path then
    local ok, data = pcall(vim.fn.readfile, path)
    if ok and data then
      vars = parse_dotenv(table.concat(data, "\n"), vars)
    end
  end
  _dotenv_cache[search_dir] = vars
  _dotenv_cache_mtime[search_dir] = mtime
  return vars
end

--- Load env.json vars for the current env (matches Rust --env flow).
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
  local vars = envs[state.current_env or "dev"]
  if type(vars) ~= "table" then return {} end
  local result = {}
  for k, v in pairs(vars) do result[k] = v end
  return result
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

--- Read + cache the connections.toml table (mtime invalidated).
--- @return table|nil, string|nil parsed, error
local function read_config(search_dir)
  local config_path = M.find_connections_toml(search_dir)
  if not config_path then return nil, "connections.toml not found" end
  local mtime = vim.fn.getftime(config_path)
  if _config_cache_path ~= config_path or _config_cache_mtime ~= mtime then
    local toml = require("poste-redis.toml")
    local parsed, err = toml.parse_file(config_path)
    if not parsed then return nil, err end
    _config_cache = parsed
    _config_cache_path = config_path
    _config_cache_mtime = mtime
  end
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
--- @return string|nil, string|nil
local function build_url_from_fields(conn)
  local scheme = conn.tls and "rediss" or "redis"
  local host = conn.host
  if not host or host == "" then
    return nil, "Missing host for redis connection"
  end
  local port = conn.port or 6379
  local db = conn.db or 0
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
  return build_url_from_fields(conn)
end

--- List redis connections: { { name, url, host, port, db }, ... } (async cb).
--- @param callback function(list: table[])
--- @param opts? table { search_dir = string|nil }
local function list_connections_sync(search_dir)
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
        url = build_url_from_fields(resolved)
      end
      local host = resolved.host
      if not host and url then
        host = url:match("^rediss?://([^/@]+)@") or url:match("^rediss?://([^:/]+)")
      end
      local db = resolved.db
      if not db and url then db = url:match("/(%d+)$") end
      table.insert(list, {
        name = name,
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

function M.list_connections(callback, opts)
  local search_dir = (opts and opts.search_dir) or get_search_dir()
  local list = list_connections_sync(search_dir)
  vim.schedule(function() callback(list) end)
end

--- Sorted redis connection names (completion / picker hints). Sync.
--- @param search_dir string|nil
--- @return string[]
function M.redis_connection_names(search_dir)
  local list = list_connections_sync(search_dir or get_search_dir())
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
    local ok, select_mod = pcall(require, "poste.select")
    if not ok then
      vim.notify("poste.select unavailable", vim.log.levels.ERROR, { title = redis_state.TITLE })
      return
    end
    select_mod.select(items, "Select Redis Connection", function(selected)
      if not selected then return end
      for _, c in ipairs(list) do
        if string.format("%s  %s", c.name, redis_util.redact_url(c.url or "")) == selected then
          M.apply_connection(c.name, c.url)
          vim.notify("Redis connection: " .. c.name, vim.log.levels.INFO, { title = redis_state.TITLE })
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
  list_connections_sync = list_connections_sync,
  --- Drop every file/mtimes cache (specs use temp dirs).
  reset_caches = function()
    _config_search_cache = {}
    _config_search_cache_mtime = {}
    _config_cache = nil
    _config_cache_path = nil
    _config_cache_mtime = nil
    _dotenv_cache = {}
    _dotenv_cache_mtime = {}
  end,
}

return M
