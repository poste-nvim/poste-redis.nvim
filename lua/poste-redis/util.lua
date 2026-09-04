--- Shared helpers (no cross-satellite requires; see family red line).
local M = {}

--- Strip credentials from a redis URL for logs: redis://user:pass@host →
--- redis://***@host. The password never lands in any log or message.
--- @param url string
--- @return string
function M.redact_url(url)
  if type(url) ~= "string" then return url end
  return url:gsub("://([^/@]+)@.*/", function(u)
    if u:find(":") then
      return "://***@"
    end
    return "://" .. u .. "@"
  end)
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
--- @param s string
--- @return string
function M.escape_for_line(s)
  if type(s) ~= "string" then return tostring(s) end
  return s:gsub("\r\n", "⏎"):gsub("\n", "⏎"):gsub("\r", "⏎"):gsub("\t", "  ")
end

--- Raw value for the clipboard (yank cell/column): keeps strings verbatim
--- (no escape, no quotes), numbers as integers, tables as compact JSON.
--- @param v any
--- @return string
function M.to_clipboard(v)
  if v == nil or v == vim.NIL then return "" end
  if type(v) == "boolean" then return v and "true" or "false" end
  if type(v) == "number" then
    if v == math.floor(v) and math.abs(v) < 1e15 then
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

return M
