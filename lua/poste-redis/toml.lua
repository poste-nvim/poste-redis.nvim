-- VENDORED from poste-db.nvim lua/poste-db/toml.lua
-- Source commit: c3f2de5 ("rename lua/poste-sql/ → lua/poste-db/, update all module paths")
-- Syncing: poste-redis must not require("poste-db.*") (family red line). This
-- pure-function TOML parser is copied here verbatim; when poste-db updates it,
-- re-copy the file and bump the commit above. Keep it dependency-free.

--- Minimal pure-Lua TOML parser.
--- Supports: [section] headers, key = "string", key = 'string', key = 123,
--- key = true/false, # comments, inline comments (outside strings),
--- basic escape sequences.
--- Returns { [section] = { key = value, ... }, ... }
local M = {}

local function trim(s)
  return s:match("^%s*(.-)%s*$")
end

local function strip_inline_comment(s)
  local i = 1
  local in_string = false
  local string_char = nil
  while i <= #s do
    local ch = s:sub(i, i)
    if in_string then
      if ch == "\\" then
        i = i + 2
      elseif ch == string_char then
        in_string = false
        i = i + 1
      else
        i = i + 1
      end
    elseif ch == '"' or ch == "'" then
      in_string = true
      string_char = ch
      i = i + 1
    elseif ch == "#" then
      return s:sub(1, i - 1)
    else
      i = i + 1
    end
  end
  return s
end

local function parse_value(v)
  v = trim(strip_inline_comment(v))
  if v == "" then return nil end
  if v == "true" then return true end
  if v == "false" then return false end
  local n = tonumber(v)
  if n then return n end
  if v:sub(1, 1) == '"' then
    if v:sub(-1, -1) ~= '"' then return nil, "Unclosed string: " .. v end
    v = v:sub(2, -2)
    v = v:gsub('\\"', '"')
    v = v:gsub("\\\\", "\\")
    v = v:gsub("\\n", "\n")
    v = v:gsub("\\t", "\t")
    v = v:gsub("\\r", "\r")
    v = v:gsub("\\b", "\b")
    v = v:gsub("\\f", "\f")
    return v
  end
  if v:sub(1, 1) == "'" then
    if v:sub(-1, -1) ~= "'" then return nil, "Unclosed string: " .. v end
    return v:sub(2, -2)
  end
  return v
end

--- Parse TOML string content.
--- @param content string Raw TOML text
--- @return table|nil, string|nil parsed table, error_message
function M.parse(content)
  local result = {}
  local section = result

  for line in content:gmatch("([^\n]*)\n?") do
    local trimmed = trim(line)
    if trimmed == "" or trimmed:sub(1, 1) == "#" then
    elseif trimmed:sub(1, 1) == "[" then
      local close = trimmed:find("]", 2)
      if not close then
        return nil, "Invalid table header: " .. line
      end
      local name = trim(trimmed:sub(2, close - 1))
      if name == "" then
        return nil, "Empty table header"
      end
      if not result[name] then
        result[name] = {}
      end
      section = result[name]
    else
      local eq = trimmed:find("=", 1, true)
      if not eq then
        return nil, "Invalid key=value line: " .. line
      end
      local key = trim(trimmed:sub(1, eq - 1))
      local val, err = parse_value(trimmed:sub(eq + 1))
      if err then return nil, err end
      if key == "" then
        return nil, "Empty key in line: " .. line
      end
      section[key] = val
    end
  end

  return result, nil
end

--- Parse TOML from file.
--- @param filepath string Path to TOML file
--- @return table|nil, string|nil parsed table, error_message
function M.parse_file(filepath)
  local ok, data = pcall(vim.fn.readfile, filepath)
  if not ok or not data then
    return nil, "Failed to read " .. filepath
  end
  return M.parse(table.concat(data, "\n"))
end

return M
