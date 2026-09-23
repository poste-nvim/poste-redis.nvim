--- Shared helpers (no cross-satellite requires; see family red line).
--- `clean_nil` / `find_file_upwards` / `ensure_job_data` are merged from
--- poste.nvim@5b3759e lua/poste/util.lua (family dissolution).
local M = {}

--- Largest magnitude a double represents every integer below exactly
--- (2^53 = 9007199254740992). Integral values under it print all their
--- digits; above it the decode already rounded them, so scientific form is
--- the honest display. The bound used to be 1e15, which threw away digits
--- that were there: a microsecond timestamp (1.7e15) came back as "1.7e+15"
--- both on screen and in a yanked cell.
M.INT_EXACT = 2^53

--- Strip credentials from a redis URL for logs: redis://user:pass@host →
--- redis://***@host. The password never lands in any log or message. The
--- pattern must only eat the userinfo — a greedy `.*` here used to swallow
--- the host too (redis://***@0).
--- @param url string
--- @return string
function M.redact_url(url)
  if type(url) ~= "string" then return url end
  return (url:gsub("://([^/@]+)@", function(u)
    if u:find(":") then
      return "://***@"
    end
    return "://" .. u .. "@"
  end))
end

--- Redact a command arg list (args 1 = command name; URL-typed args redacted).
--- @param cmd table[]
--- @return table[]
function M.redact_cmd(cmd)
  local out = {}
  for _, v in ipairs(cmd or {}) do
    if type(v) == "string" and v:match("^rediss?://") then
      out[#out + 1] = "<redacted>"
    else
      out[#out + 1] = v
    end
  end
  return out
end

--- Credential-free host label for a connection reference: plain names pass
--- through; a redis:// URL renders as its host with userinfo stripped
--- (redis://user:pass@host:6379 → host:6379).
--- @param conn string|nil
--- @return string|nil
function M.host_label(conn)
  if type(conn) ~= "string" then return conn end
  if conn:sub(1, 8) ~= "redis://" and conn:sub(1, 9) ~= "rediss://" then
    return conn
  end
  local redacted = conn:gsub("//([^/@]+)@", "//***@")
  return redacted:match("@([^/]+)") or redacted:match("^%a+://([^/]+)") or redacted
end

--- Escape literal % so a winbar/statusline's %-encoding passes user text
--- through. Parenthesized: gsub's second return must not leak.
--- @param s string
--- @return string
function M.escape_winbar(s)
  return (s:gsub("%%", "%%%%"))
end

--- Display width (CJK/emoji-aware via strdisplaywidth).
--- @param s any
--- @return number
function M.display_width(s)
  if not s then return 0 end
  if type(s) ~= "string" then s = tostring(s) end
  local ok, w = pcall(vim.fn.strdisplaywidth, s)
  return ok and w or #s
end

--- Truncate to a display width, reserving one cell for the ellipsis.
--- Never splits a UTF-8 char.
--- @param s string
--- @param max_width number
--- @return string
function M.truncate_display(s, max_width)
  if not s then return "" end
  if type(s) ~= "string" then s = tostring(s) end
  if M.display_width(s) <= max_width then return s end
  local out, w = {}, 0
  for _, ch in ipairs(vim.fn.split(s, "\\zs")) do
    local cw = M.display_width(ch)
    if w + cw > max_width - 1 then break end
    w = w + cw
    out[#out + 1] = ch
  end
  return table.concat(out) .. "…"
end

--- Pad right to a display width.
--- @param s string
--- @param width number
--- @return string
function M.pad_right(s, width)
  local w = M.display_width(s or "")
  if w >= width then return s end
  return s .. string.rep(" ", width - w)
end

--- Pad left to a display width.
--- @param s string
--- @param width number
--- @return string
function M.pad_left(s, width)
  local w = M.display_width(s or "")
  if w >= width then return s end
  return string.rep(" ", width - w) .. s
end

--- Escape control chars for display in a single table line.
--- The parens are the function: `gsub` returns the count as a second value,
--- and a caller that splices this into a table constructor (`{ cell(v) }` in
--- format.lua) would append that number as an extra "line" of the panel.
--- NUL is mapped too: a `\x00` escape decodes to a real NUL byte (binary-safe
--- keys), and a NUL reaching a buffer line is coerced to a newline by Neovim —
--- the escape keeps it one visible character instead of splitting the row.
--- @param s string
--- @return string
function M.escape_for_line(s)
  if type(s) ~= "string" then return tostring(s) end
  return (s:gsub("\r\n", "⏎"):gsub("\n", "⏎"):gsub("\r", "⏎"):gsub("\t", "  "):gsub("%z", "\\0"))
end

--- Escape redis glob metacharacters so a literal string (a key name or a
--- key-derived prefix) matches only itself in a SCAN `MATCH` pattern.
--- Redis globs: `*`, `?`, `[`, `]` and the `\` escape itself.
--- @param s any
--- @return any
function M.glob_escape(s)
  if type(s) ~= "string" then return s end
  return (s:gsub("[%*%?%[%]\\]", "\\%0"))
end

--- Is `s` exactly `<hh> <hh> …` — the body of one of the binary markers?
---
--- Written as a loop rather than `^%x%x( %x%x)*$` because Lua's matcher will
--- not anchor a capture through a repetition: that pattern returns nil on
--- "ff fe" in this runtime (Lua 5.1 leaves a capture inside a repeated item
--- unspecified), which is how the first version of this check silently
--- matched nothing. Splitting on whitespace says "every run is one byte", and
--- counting the spaces says the joins were single — `hex:ff  fe` is not a
--- rendering the binary produces.
--- @param s string
--- @return boolean
local function hex_pairs(s)
  local n = 0
  for part in s:gmatch("%S+") do
    if not part:match("^%x%x$") then return false end
    n = n + 1
  end
  if n == 0 then return false end
  return (s:gsub("%S", "")) == string.rep(" ", n - 1)
end

--- Does this text stand in for bytes the transport cannot carry?
---
--- poste.nvim's redis executor renders non-UTF-8 payloads two ways: a NAME (a
--- hash field, a zset member) becomes `hex:<pairs>` and a VALUE becomes
--- `(binary) N bytes hex: <pairs>` (capped previews, so always whole pairs).
--- Both are for reading only — `HDEL key "hex:ff fe"` matches no field and
--- still answers OK. Anything that writes a cell back has to know.
---
--- A UTF-8 entry genuinely named `hex:ff fe` matches too, and the guard this
--- feeds refuses it: losing the grid editor on such a name is the cheap side
--- of the trade, since the other option is writing to the wrong entry.
--- @param s any
--- @return boolean
function M.is_hex_display(s)
  if type(s) ~= "string" then return false end
  local hex = s:match("^hex:(.*)$")
      or s:match("^%(binary%) %d+ bytes hex:%s*(.*)$")
  return hex ~= nil and hex_pairs(hex)
end

--- Render a command token list as the display/history line. Tokens that are
--- empty or contain whitespace, a double quote or a backslash are double-
--- quoted with escapes, so a key `a b` records as `DEL "a b"` instead of the
--- ambiguous `DEL a b` (three args on read-back). Clean tokens stay verbatim.
--- @param args table[]  token list (args[1] = command name)
--- @return string
function M.render_command(args)
  local out = {}
  for i, a in ipairs(args or {}) do
    a = tostring(a)
    if a == "" or a:find("[%s\"\\]") then
      a = '"' .. a:gsub("\\", "\\\\"):gsub("\"", "\\\"") .. '"'
    end
    out[i] = a
  end
  return table.concat(out, " ")
end

--- Raw value for the clipboard (yank cell/column): keeps strings verbatim
--- (no escape, no quotes), numbers as integers, tables as compact JSON.
--- @param v any
--- @return string
function M.to_clipboard(v)
  if v == nil or v == vim.NIL then return "" end
  if type(v) == "boolean" then return v and "true" or "false" end
  if type(v) == "number" then
    if v == math.floor(v) and math.abs(v) < M.INT_EXACT then
      return string.format("%.0f", v)
    end
    return tostring(v)
  end
  if type(v) == "table" then
    local ok, s = pcall(vim.json.encode, v)
    return ok and s or vim.inspect(v)
  end
  return tostring(v)
end

--- Format latency for display (ms → ms/s).
--- @param ms number
--- @return string
function M.format_latency(ms)
  if not ms then return "" end
  if ms >= 1000 then return string.format("%.2f s", ms / 1000) end
  return string.format("%.0f ms", ms)
end

---------------------------------------------------------------------------
-- Merged from poste.nvim@5b3759e lua/poste/util.lua (family dissolution)
---------------------------------------------------------------------------

--- Recursively remove vim.NIL values from a parsed JSON table.
---
--- `vim.json.decode` converts JSON `null` to `vim.NIL`. This function
--- replaces those values with Lua `nil` so they can be safely compared
--- with `== nil`. It mutates the table in place and also returns it.
---
--- @param t table|nil  A table from vim.json.decode, or nil
--- @return table|nil    The same table with vim.NIL values removed, or nil
function M.clean_nil(t)
  if not t or type(t) ~= "table" then return t end
  for k, v in pairs(t) do
    if v == vim.NIL then
      t[k] = nil
    elseif type(v) == "table" then
      M.clean_nil(v)
    end
  end
  return t
end

--- Walk up the directory tree from `start_dir` to find a file.
--- Checks each ancestor directory for the given filename, stopping at
--- the filesystem root. Returns the first matching absolute path, or nil.
---
--- @param filename  string  File name to search for (e.g. "env.json")
--- @param start_dir string  Directory to start searching from
--- @return string|nil       Absolute path to the found file, or nil
function M.find_file_upwards(filename, start_dir)
  if not filename or filename == "" then return nil end
  local dir = start_dir or vim.fn.getcwd()
  while true do
    local candidate = dir .. "/" .. filename
    if vim.fn.filereadable(candidate) == 1 then
      return candidate
    end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then
      return nil
    end
    dir = parent
  end
end

--- Given an array of lines from a job's stdout/stderr callback, remove
--- trailing empty strings. Neovim's jobstart callbacks often include
--- one or more trailing empty strings; this is a safe normalizer.
---
--- Returns the same array (mutated in place) with trailing empties
--- removed, for consistency with existing calling conventions.
---
--- @param data string[]|nil  Lines from a job callback
--- @return string[]          Cleaned array (may be empty)
function M.ensure_job_data(data)
  if not data or type(data) ~= "table" then return {} end
  while #data > 0 and data[#data] == "" do
    data[#data] = nil
  end
  return data
end

--- Append the strings of `src` that `seen` has not recorded yet, marking them.
--- SCAN's iteration contract is at-least-once: the same key can be returned on
--- two pages of one walk (the cursor is a bucket index, and a rehash mid-scan
--- revisits buckets), so every browser accumulator dedups through here —
--- otherwise one key renders as two rows and a group's child count is too high.
--- Non-string entries (a nested reply from a weird server) are skipped.
--- @param dst string[]   accumulator (mutated)
--- @param seen table<string, true>  keys already collected (mutated)
--- @param src table[]    one SCAN page's key list
function M.append_new(dst, seen, src)
  for _, v in ipairs(src or {}) do
    if type(v) == "string" and not seen[v] then
      seen[v] = true
      dst[#dst + 1] = v
    end
  end
end

return M
