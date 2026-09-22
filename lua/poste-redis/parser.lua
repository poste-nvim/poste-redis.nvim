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
--- stopping at the first *standalone* `#` or `--` comment. Quote-aware: `#`
--- inside quotes never starts a comment. Quotes are kept on the token
--- (stripped later by unquote) so `a # b` inside a string round-trips.
---
--- "Standalone" mirrors the syntax file (`\s\+#` / `\s\+--`): a comment
--- starter must sit at a word boundary, i.e. right after whitespace. Redis
--- keys are binary-safe — `user#1` and `hash--tag` are legal key names — and
--- a comment check that fires mid-word silently retargets the command
--- (`SET user#1 v` would become `SET user v`, a write to a key that was
--- never named). Quoted tokens keep the old behaviour available for a key
--- that itself starts with `--` (`GET "--key"`).
--- @param line string
--- @return string[]
local function tokenize_line(line)
  local tokens = {}
  local i = 1
  local n = #line
  while i <= n do
    local c = line:sub(i, i)
    local prev = i > 1 and line:sub(i - 1, i - 1) or " "
    local at_boundary = prev == " " or prev == "\t"
    if c == " " or c == "\t" then
      i = i + 1
    elseif c == "#" and at_boundary then
      break
    elseif c == "-" and at_boundary and line:sub(i, i + 1) == "--" then
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
      -- A bare word runs to whitespace; a `#` glued to it belongs to the word
      -- (the comment decision happened at the top of the loop, where the
      -- boundary was still visible).
      local word_end = line:find("%s", i)
      if not word_end then word_end = n + 1 end
      tokens[#tokens + 1] = line:sub(i, word_end - 1)
      i = word_end
    end
  end
  return tokens
end

--- Strip surrounding quotes from a token. Double quotes: JSON-compatible
--- escapes (\", \\, \n, \t, \r). Single quotes: literal (redis-cli style).
--- Decoding is ONE pass over `\x` pairs: sequential gsub passes would let
--- `\\n` (backslash + n per JSON) re-match as `\n` after `\\` → `\` and
--- decode to a newline instead of the literal two characters.
--- @param tok string
--- @return string
local function unquote(tok)
  local first = tok:sub(1, 1)
  local last = tok:sub(-1, -1)
  if (first == '"' or first == "'") and last == first and #tok >= 2 then
    local inner = tok:sub(2, -2)
    if first == '"' then
      inner = inner:gsub("\\(.)", function(e)
        if e == '"' then return '"' end
        if e == "\\" then return "\\" end
        if e == "n" then return "\n" end
        if e == "t" then return "\t" end
        if e == "r" then return "\r" end
        return "\\" .. e  -- unknown escape: keep both characters verbatim
      end)
    end
    return inner
  end
  return tok
end

--- The decoded command head: quotes stripped, uppercased. Tokens keep the
--- quotes as written (for `raw` / the panel title), so everything that DECIDES
--- something from the name has to decode it first — above all the danger
--- blacklist, which `"FLUSHALL"` would otherwise slip past with the quotes
--- still attached, and the server would reject that name anyway.
--- @param tok string|nil
--- @return string
local function head_of(tok)
  return unquote(tok or ""):upper()
end

--- Build a command entry.
--- @param tokens string[]  quoted as written; only `command` is decoded
--- @return table entry
local function command_entry(tokens, start_line, end_line)
  return {
    kind = "command",
    tokens = tokens,
    command = head_of(tokens[1]),
    start_line = start_line,
    end_line = end_line,
    raw = table.concat(tokens, " "),
  }
end

--- Build a USE entry. The connection name is decoded like the command head:
--- `USE "local"` is the same section as `USE local`, and a name kept verbatim
--- would fail `connections.resolve` with the quotes still attached.
local function use_entry(tokens, start_line, end_line)
  return {
    kind = "use",
    tokens = tokens,
    connection = tokens[2] and unquote(tokens[2]) or nil,
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
    local is_use = type(first) == "string" and head_of(first) == "USE"
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
--- Falls back to current '< '>' marks when no range given. Zero/negative
--- lines count as "no range" — Lua 0 is truthy, so a bare `not s_line` let
--- an unset mark (line 0) slip through and match nothing.
--- @param buf number
--- @param opts? table { start_line = number, end_line = number }
--- @return table[]
function M.visual_entries(buf, opts)
  opts = opts or {}
  local s_line = opts.start_line
  local e_line = opts.end_line
  if not s_line or s_line < 1 or not e_line or e_line < 1 then
    local start_pos = vim.fn.getpos("'<")
    local end_pos = vim.fn.getpos("'>")
    s_line = start_pos[2]
    e_line = end_pos[2]
  end
  if not s_line or s_line < 1 or not e_line or e_line < 1 then return {} end
  if e_line < s_line then s_line, e_line = e_line, s_line end
  local entries = M.buffer_entries(buf)
  local result = {}
  for i, e in ipairs(entries) do
    -- overlap test: the entry's line range intersects [s_line, e_line]
    if not (e.end_line < s_line or e.start_line > e_line) then
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
      out[1] = head_of(t)
    else
      out[i] = unquote(t)
    end
  end
  return out
end

--- True when the entry is a dangerous command (FLUSHALL/FLUSHDB/SHUTDOWN/
--- CONFIG ...). Drives the result panel's yellow warning and the runner's
--- confirm gate. Delegates to constants so the blacklist has a single
--- source of truth. `entry.command` is decoded, so quoting the head does not
--- slip past it.
--- @param entry table
--- @return boolean
function M.is_dangerous(entry)
  if entry.kind ~= "command" then return false end
  return constants.is_dangerous_command(entry.command)
end

--- Command heads whose SECOND token is not a key name.
---
--- A key extracted here drives three visible things: the `gd` reveal in
--- the browser tree, the result panel tab's `meta.key` (and the grid editors
--- bound to it), and the winbar's best-effort `TTL <key>` probe. A false
--- positive therefore sends a cursor, glob, channel, Lua body, subcommand
--- word or credential to the server as if it were a key name.
---
--- Membership is by argument SHAPE, not by Redis command group: a head
--- belongs here only when the command has no key or names it at another
--- position. `HSCAN key 0`, `BLPOP key 5`, `SORT key BY …` and
--- `XRANGE key - +` are deliberately absent — their key IS the second token.
--- Callers pass `command_tokens` output, so the head is already unquoted and
--- uppercased: `"scan"` cannot slip past this list (same rule as the danger
--- blacklist in constants).
local NOT_KEY_HEADS = {
  -- session directives, never sent as key lookups
  USE = true, SELECT = true,
  -- scanning: the first argument is a cursor or a glob, not a key
  SCAN = true, KEYS = true,
  -- script/function: body or name comes first, keys follow a count
  EVAL = true, EVALSHA = true, FCALL = true, FCALL_RO = true,
  -- pubsub: channels live in their own namespace, not in the keyspace
  SUBSCRIBE = true, UNSUBSCRIBE = true, PSUBSCRIBE = true, PUNSUBSCRIBE = true,
  SSUBSCRIBE = true, SUNSUBSCRIBE = true, PUBLISH = true, PUBSUB = true,
  -- streams read: the keys come after the STREAMS keyword
  XREAD = true, XREADGROUP = true,
  -- key-count-first: `LMPOP numkeys key …`
  LMPOP = true, ZMPOP = true, SINTERCARD = true,
  -- key at a LATER position: `<CMD> <subcommand> key …`
  OBJECT = true, MEMORY = true, XGROUP = true, XINFO = true,
  -- server administration: subcommand, section, number or path
  CONFIG = true, CLIENT = true, COMMAND = true, ACL = true, SCRIPT = true,
  FUNCTION = true, LATENCY = true, SLOWLOG = true, CLUSTER = true,
  MODULE = true, INFO = true, DEBUG = true, SHUTDOWN = true,
  -- connection handshake / server-to-server: host, port, db index, password
  AUTH = true, HELLO = true, MIGRATE = true, SWAPDB = true, WAIT = true,
  WAITAOF = true,
}

--- The key argument of a tokenized command (nil when the command does not
--- address a key). Shared by gd reveal, the result panel's tab binding, the
--- history replay and grid editing.
--- @param tokens string[]  command_tokens output (de-quoted, uppercased head)
--- @return string|nil key
function M.key_arg(tokens)
  if not tokens or #tokens < 2 then return nil end
  if NOT_KEY_HEADS[tokens[1]] then return nil end
  return tokens[2]
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
      tokens[1] = head_of(t)
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
