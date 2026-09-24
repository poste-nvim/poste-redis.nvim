-- VENDORED from poste-db.nvim lua/poste-db/toml.lua
-- Source commit: 9516208 ("fix(toml): a fully-quoted key or header is one
-- name, dots and all"). The copy pinned to 89f0468 rejected the legal TOML
-- shape `"my.key" = …` as a dotted key and stored quoted header names with
-- their quote characters; the copy pinned to 94fccf2 before that was missing
-- the inline table/array parsing poste-db added in cc6652e.
-- Syncing: poste-redis must not require("poste-db.*") (family red line), so
-- this pure-function parser is copied verbatim — including doc comments and
-- poste-db-only examples in them. When poste-db updates the file, re-copy it
-- whole and bump the commit above. Keep it dependency-free.

--- Minimal pure-Lua TOML parser.
--- Supports: [section] headers (quoted header names too), key = "string" /
--- 'string' / 123 / true|false, inline arrays `[…]` and inline tables `{…}`
--- (the shapes connections.toml uses for `tunnel = { … }`), # comments,
--- inline comments (outside strings), basic escape sequences.
--- Deliberately unsupported: [[array-of-tables]], dotted keys and multi-line
--- values — the first two error out rather than producing a bogus key, the
--- last is rare in a config file. A fully-quoted key is ONE name and may
--- carry dots (`"my.key" = …` is legal TOML; it used to die as a dotted
--- key); an unquoted dotted key still errors. Unquoted values (dates, bare
--- words) come back as strings.
--- Returns { [section] = { key = value, ... }, ... }
local M = {}

local function trim(s)
  return s:match("^%s*(.-)%s*$")
end

local function strip_inline_comment(s)
  local i = 1
  local in_string = false
  local string_char = nil
  -- TOML basic strings ("…") process backslash escapes; literal strings
  -- ('…') process NONE — skipping 2 chars after a `\` in a literal string
  -- ate the closing quote of values like 'a\' and turned a trailing
  -- comment into a spurious "Unclosed single-quoted string" error.
  local escaped = false
  while i <= #s do
    local ch = s:sub(i, i)
    if in_string then
      if escaped then
        escaped = false
        i = i + 1
      elseif string_char == '"' and ch == "\\" then
        escaped = true
        i = i + 1
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

local BASIC_ESCAPES = {
  ['"'] = '"', ["\\"] = "\\", n = "\n", t = "\t", r = "\r", b = "\b", f = "\f",
}

local function unescape_basic(s)
  -- single pass: sequential gsubs re-process what earlier ones produced
  -- ("D:\\tables\\notes" — the \t of \tables must stay backslash + t)
  return (s:gsub("\\(.)", function(c)
    return BASIC_ESCAPES[c] or ("\\" .. c)
  end))
end

local parse_value  -- forward: inline containers recurse into it

--- Split a value body on a top-level delimiter, keeping quoted strings and
--- nested `[...]`/`{...}` intact (so `["a,b", "c"]` splits into two items).
local function split_top(s, sep)
  local parts, buf = {}, {}
  local depth, i, quote = 0, 1, nil
  while i <= #s do
    local ch = s:sub(i, i)
    if quote then
      table.insert(buf, ch)
      if ch == "\\" and quote == '"' then
        table.insert(buf, s:sub(i + 1, i + 1))
        i = i + 2
      elseif ch == quote then
        quote = nil
        i = i + 1
      else
        i = i + 1
      end
    elseif ch == '"' or ch == "'" then
      quote = ch
      table.insert(buf, ch)
      i = i + 1
    elseif ch == "{" or ch == "[" then
      depth = depth + 1
      table.insert(buf, ch)
      i = i + 1
    elseif ch == "}" or ch == "]" then
      depth = depth - 1
      table.insert(buf, ch)
      i = i + 1
    elseif ch == sep and depth == 0 then
      table.insert(parts, table.concat(buf))
      buf = {}
      i = i + 1
    else
      table.insert(buf, ch)
      i = i + 1
    end
  end
  table.insert(parts, table.concat(buf))
  return parts
end

--- Inline array (`[1, 2]`) / inline table (`{ to = "h", port = 2222 }`).
--- Without these, `tunnel = { … }` — a shape tunnel.normalize_cfg documents —
--- came back as the raw string and every tunneled connection failed to match.
local function parse_container(v)
  local is_array = v:sub(1, 1) == "["
  local closer = is_array and "]" or "}"
  if v:sub(-1, -1) ~= closer then
    return nil, is_array and "Unclosed inline array" or "Unclosed inline table"
  end
  local body = v:sub(2, -2)
  if is_array then
    local out = {}
    if trim(body) == "" then return out end
    for _, part in ipairs(split_top(body, ",")) do
      local item, err = parse_value(part)
      if err then return nil, err end
      if item ~= nil then table.insert(out, item) end
    end
    return out
  end
  local out = {}
  if trim(body) == "" then return out end
  for _, part in ipairs(split_top(body, ",")) do
    local pair = trim(part)
    if pair ~= "" then
      local eq = pair:find("=", 1, true)
      if not eq then return nil, "Invalid inline table entry" end
      local key = parse_value(pair:sub(1, eq - 1))
      local val, err = parse_value(pair:sub(eq + 1))
      if err then return nil, err end
      out[tostring(key)] = val
    end
  end
  return out
end

parse_value = function(v)
  v = trim(strip_inline_comment(v))
  if v == "" then return nil end
  if v == "true" then return true end
  if v == "false" then return false end
  local n = tonumber(v)
  if n then return n end
  -- NB: the error must not quote the value — connections.toml values are
  -- frequently secrets, and the message goes to the log file.
  if v:sub(1, 1) == '"' then
    if v:sub(-1, -1) ~= '"' then return nil, "Unclosed double-quoted string" end
    return unescape_basic(v:sub(2, -2))
  end
  if v:sub(1, 1) == "'" then
    if v:sub(-1, -1) ~= "'" then return nil, "Unclosed single-quoted string" end
    return v:sub(2, -2)
  end
  if v:sub(1, 1) == "[" or v:sub(1, 1) == "{" then
    return parse_container(v)
  end
  return v
end

--- Parse TOML string content.
--- @param content string Raw TOML text
--- @return table|nil, string|nil parsed table, error_message
function M.parse(content)
  -- editors and Windows tools routinely save with a UTF-8 BOM; without
  -- stripping it the first line fails as "Invalid key=value line"
  content = content:gsub("^\xEF\xBB\xBF", "")
  local result = {}
  local section = result

  for line in content:gmatch("([^\n]*)\n?") do
    local trimmed = trim(line)
    if trimmed == "" or trimmed:sub(1, 1) == "#" then -- luacheck: ignore 542
    elseif trimmed:sub(1, 1) == "[" then
      -- [[array-of-tables]] would otherwise parse into a section literally
      -- named "[name", so the connection silently vanishes from the list.
      -- A dotted [a.b] header stays a flat section called "a.b" on purpose:
      -- the header IS the connection name, so `my-app.prod` is legal.
      if trimmed:sub(1, 2) == "[[" then
        return nil, "Array-of-tables headers ([[name]]) are not supported"
      end
      local close, name
      local q = trimmed:sub(2, 2)
      if q == '"' or q == "'" then
        -- A quoted header name is ONE literal name: it may contain `]` or a
        -- dot, which the first-`]` scan used to cut in half (and left the
        -- quote characters in the stored section name).
        local close_q = trimmed:find(q, 3, true)
        if not close_q or trim(trimmed:sub(close_q + 1, -2)) ~= "" then
          return nil, "Invalid table header: " .. line
        end
        close = close_q + 1
        name = q == '"' and unescape_basic(trimmed:sub(3, close_q - 1))
          or trimmed:sub(3, close_q - 1)
      else
        close = trimmed:find("]", 2)
        if not close then
          return nil, "Invalid table header: " .. line
        end
        name = trim(trimmed:sub(2, close - 1))
      end
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
        -- the raw line can be a mistyped `password "x"`, so it is not echoed
        return nil, "Invalid key=value line (expected `key = value`)"
      end
      local key = trim(trimmed:sub(1, eq - 1))
      local val, err = parse_value(trimmed:sub(eq + 1))
      if err then return nil, err end
      if key == "" then
        return nil, "Empty key in line"
      end
      -- A fully-quoted key unquotes to ONE name whose dots are its own:
      -- `"my.key" = …` is legal TOML (it used to die as a dotted key).
      -- Anything else — bare keys, and quoted fragments like `"a"."b"` —
      -- keeps the documented dotted-key rejection.
      local single_quoted_name = false
      local q = key:sub(1, 1)
      if (q == '"' or q == "'") and #key >= 2 then
        local close_q
        if q == "'" then
          close_q = key:find("'", 2, true)
        else
          -- a basic string may carry escaped quotes: "a\"b" ends at the LAST one
          local i = 2
          while i <= #key do
            local c = key:sub(i, i)
            if c == "\\" then
              i = i + 2
            elseif c == '"' then
              break
            else
              i = i + 1
            end
          end
          close_q = i <= #key and i or nil
        end
        if close_q == #key then
          key = q == '"' and unescape_basic(key:sub(2, -2)) or key:sub(2, -2)
          single_quoted_name = true
        end
      end
      -- never echo the line here: values can be passwords
      if not single_quoted_name and key:find(".", 1, true) then
        return nil, "Dotted keys (a.b = …) are not supported: " .. key
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