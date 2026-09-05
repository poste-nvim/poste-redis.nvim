--- .redis file parser — the ONLY parser (poste-redis EXECUTION-PLAN D1).
--- Rust never sees file text; Lua extracts command lines (continuations
--- joined, comments quote-aware stripped, USE recognized) and sends token
--- arrays to the binary.
local constants = require("poste-redis.constants")

local M = {}

--- Normalize CRLF and split into physical lines.
--- @param content string
--- @return string[]
local function split_lines(content)
  content = content:gsub("\r\n", "\n"):gsub("\r", "\n")
  return vim.split(content, "\n", { plain = true })
end

--- Tokenize a physical line body (before continuation-join) into tokens,
--- stopping at the first bare `#` or `--` comment. Quote-aware: `#` inside
--- quotes never starts a comment. Quotes are kept on the token (stripped
--- later by unquote) so `a # b` inside a string round-trips.
--- @param line string
--- @return string[]
local function tokenize_line(line)
  local tokens = {}
  local i = 1
  local n = #line
  while i <= n do
    local c = line:sub(i, i)
    if c == " " or c == "\t" then
      i = i + 1
    elseif c == "#" then
      break
    elseif c == "-" and line:sub(i, i + 1) == "--" then
      break
    elseif c == '"' or c == "'" then
      local close = line:find(c, i + 1, true)
      while close and line:sub(close - 1, close - 1) == "\\" do
        local bs = close - 1
        local cnt = 0
        while bs >= i + 1 and line:sub(bs, bs) == "\\" do
          cnt = cnt + 1
          bs = bs - 1
        end
        if cnt % 2 == 1 then
          close = line:find(c, close + 1, true)
        else
          break
        end
      end
      if not close then close = n + 1 end
      tokens[#tokens + 1] = line:sub(i, close)
      i = close + 1
    else
      local word_end = line:find("[%s#]", i)
      if not word_end then word_end = n + 1 end
      tokens[#tokens + 1] = line:sub(i, word_end - 1)
      i = word_end
    end
  end
  return tokens
end

--- Strip surrounding quotes from a token. Double quotes: JSON-compatible
--- escapes (\", \\, \n, \t, \r). Single quotes: literal (redis-cli style).
--- @param tok string
--- @return string
local function unquote(tok)
  local first = tok:sub(1, 1)
  local last = tok:sub(-1, -1)
  if (first == '"' or first == "'") and last == first and #tok >= 2 then
    local inner = tok:sub(2, -2)
    if first == '"' then
      inner = inner:gsub('\\"', '"'):gsub("\\\\", "\\")
        :gsub("\\n", "\n"):gsub("\\t", "\t"):gsub("\\r", "\r")
    end
    return inner
  end
  return tok
end

--- Build a command entry.
local function command_entry(tokens, start_line, end_line)
  return {
    kind = "command",
    tokens = tokens,
    command = (tokens[1] or ""):upper(),
    start_line = start_line,
    end_line = end_line,
    raw = table.concat(tokens, " "),
  }
end

--- Build a USE entry.
local function use_entry(tokens, start_line, end_line)
  return {
    kind = "use",
    tokens = tokens,
    connection = tokens[2],
    start_line = start_line,
    end_line = end_line,
    raw = table.concat(tokens, " "),
  }
end

--- Extract entries from file content.
---
--- Parsing model:
---   - each command is ONE logical line of tokens; a physical line ending in
---     `\` (ignoring trailing whitespace) continues onto the next physical
---     line (tokens are concatenated, single space separator)
---   - full-line comments (`#`/`--` at line start) and blank lines terminate
---     the current logical line
---   - inline comments: first bare `#` (outside quotes) ends the logical line
---   - `USE <name>` (case-insensitive) → kind="use" entry; `USE` alone → use
---     with connection=nil (selector prompt handled by caller)
---   - commands are otherwise left "dumb": no argument semantics parsed (D6)
--- @param content string
--- @return table[] entries
function M.extract_entries(content)
  local physical = split_lines(content)
  local entries = {}
  local logical = {}         -- accumulated tokens for the current logical line
  local logical_start = nil  -- first physical line index (1-based)
  local logical_end = nil    -- last physical line index

  local function flush()
    if #logical == 0 then
      logical_start, logical_end = nil, nil
      return
    end
    local first = logical[1]
    local is_use = type(first) == "string" and first:upper() == "USE"
    local entry = is_use and use_entry(logical, logical_start, logical_end)
      or command_entry(logical, logical_start, logical_end)
    entries[#entries + 1] = entry
    logical = {}
    logical_start, logical_end = nil, nil
  end

  for idx, raw_line in ipairs(physical) do
    local line = raw_line:gsub("%s+$", "")
    local trimmed = line:match("^%s*(.-)%s*$")

    -- Full-line comment / blank → terminate any in-progress logical line.
    if trimmed == "" or trimmed:sub(1, 1) == "#" or trimmed:sub(1, 2) == "--" then
      flush()
      goto continue
    end

    local has_cont = line:sub(-1, -1) == "\\"
    local body = has_cont and line:sub(1, -2) or line
    local tokens = tokenize_line(body)
    if #tokens > 0 then
      if not logical_start then
        logical_start = idx
        logical = tokens
      else
        for _, t in ipairs(tokens) do logical[#logical + 1] = t end
      end
    end
    if #tokens > 0 then logical_end = idx end
    if not has_cont then flush() end

    ::continue::
  end
  flush()

  return entries
end

--- Physical line → entry index (1-based), or nil.
--- @param entries table[]
--- @param lnum number
--- @return number|nil
local function entry_index_at(entries, lnum)
  for i, e in ipairs(entries) do
    if lnum >= e.start_line and lnum <= e.end_line then
      return i
    end
  end
  return nil
end

--- Extract entries from a buffer's lines. Hot callers (context resolution
--- re-resolves on every cursor move / keystroke) can pass `max_line` to skip
--- parsing everything past it — entries beyond the cursor cannot affect the
--- effective USE/SELECT at it. A continuation line at the boundary parses as
--- a standalone fragment, which is harmless: fragments are never USE/SELECT.
--- @param buf number
--- @param opts? table { max_line = number }  parse only lines 1..max_line
--- @return table[]
function M.buffer_entries(buf, opts)
  opts = opts or {}
  local lines
  if opts.max_line then
    lines = vim.api.nvim_buf_get_lines(buf, 0, opts.max_line, false)
  else
    lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end
  return M.extract_entries(table.concat(lines, "\n"))
end

--- Entry containing the cursor, or nil.
--- @param buf number
--- @return table|nil
function M.cursor_entry(buf)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local entries = M.buffer_entries(buf)
  local idx = entry_index_at(entries, lnum)
  return idx and entries[idx] or nil
end

--- Entries covered by a visual selection (ordered, deduped).
--- Falls back to current '< '>' marks when no range given.
--- @param buf number
--- @param opts? table { start_line = number, end_line = number }
--- @return table[]
function M.visual_entries(buf, opts)
  opts = opts or {}
  local s_line = opts.start_line
  local e_line = opts.end_line
  if not s_line or not e_line then
    local start_pos = vim.fn.getpos("'<")
    local end_pos = vim.fn.getpos("'>")
    s_line = start_pos[2]
    e_line = end_pos[2]
  end
  if e_line < s_line then s_line, e_line = e_line, s_line end
  local entries = M.buffer_entries(buf)
  local result = {}
  local seen = {}
  for i, e in ipairs(entries) do
    if not (e.end_line < s_line or e.start_line > e_line) and not seen[i] then
      seen[i] = true
      result[#result + 1] = e
    end
  end
  return result
end

--- Full-file entries.
--- @param buf number
--- @return table[]
function M.file_entries(buf)
  return M.buffer_entries(buf)
end

--- Display text of an entry (tokens joined).
--- @param entry table
--- @return string
function M.entry_text(entry)
  return entry.raw or table.concat(entry.tokens or {}, " ")
end

--- Arg vector sent to the binary: command name uppercased, args de-quoted.
--- @param entry table
--- @return string[]
function M.entry_args(entry)
  if entry.kind == "use" then return {} end
  local out = {}
  for i, t in ipairs(entry.tokens or {}) do
    if i == 1 then
      out[1] = t:upper()
    else
      out[i] = unquote(t)
    end
  end
  return out
end

--- True when the entry is a dangerous command (FLUSHALL/FLUSHDB/SHUTDOWN/
--- CONFIG ...). M1: parser flags these; panel shows a yellow warning (red line
--- #5). Full interception lands in M3 (P2-2). Delegates to constants so the
--- blacklist has a single source of truth.
--- @param entry table
--- @return boolean
function M.is_dangerous(entry)
  if entry.kind ~= "command" then return false end
  return constants.is_dangerous_command(entry.command)
end

--- Tokenize one standalone command line into redis tokens (first token
--- uppercased, quotes stripped, comments dropped). Used by the result
--- panel's refresh to re-run the tab's command.
--- @param line string
--- @return string[]|nil tokens, string|nil error
function M.command_tokens(line)
  if not line or line == "" then return nil, "empty command" end
  local tokens = {}
  for i, t in ipairs(tokenize_line(line)) do
    if i == 1 then
      tokens[1] = t:upper()
    else
      tokens[i] = unquote(t)
    end
  end
  if #tokens == 0 then return nil, "empty command" end
  return tokens, nil
end

M._test = {
  split_lines = split_lines,
  tokenize_line = tokenize_line,
  unquote = unquote,
  entry_index_at = entry_index_at,
  command_entry = command_entry,
  use_entry = use_entry,
}

return M
