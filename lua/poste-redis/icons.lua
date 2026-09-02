--- Shared nerd-font glyphs + type colors for redis key types.
--- Used by the browser tree (node icons) and the result grid (the first
--- column header shows the icon + type, colored like the tree icon).
local M = {}

--- Redis key type → glyph. TYPE only reports string/zset/hash/... so the
--- subtype glyphs (bitmap/bitfield/hyperloglog/geo) resolve via TYPE fallback
--- in the browser; the grid header uses the collection types directly.
M.KEY_ICON = {
  string = "",
  zset = "",
  hash = "󰘦",
  list = "",
  set = "󰸳",
  stream = "",
  bitmap = "󱗼",
  bitfield = "󱗼",
  bitfields = "󱗼",
  hyperloglog = "󱗼",
  hyperlonglong = "󱗼",
  geo = "",
}

--- Structural node icons (browser tree).
M.ICON = {
  connection = "",
  db = "",
  group = "",
  key = "",
}

--- Highlight group per key type: collections orange, string green, everything
--- else (stream/bitmap/geo/unknown) purple. Shared by tree icons and the
--- result grid's type header cell.
M.KEY_HL = {
  string = "PosteRedisBrowserString",
  zset = "PosteRedisBrowserCollection",
  hash = "PosteRedisBrowserCollection",
  list = "PosteRedisBrowserCollection",
  set = "PosteRedisBrowserCollection",
  stream = "PosteRedisBrowserOther",
  bitmap = "PosteRedisBrowserOther",
  bitfield = "PosteRedisBrowserOther",
  bitfields = "PosteRedisBrowserOther",
  hyperloglog = "PosteRedisBrowserOther",
  hyperlonglong = "PosteRedisBrowserOther",
  geo = "PosteRedisBrowserOther",
}

--- "icon + type" label for a grid's index-column header, e.g. " string".
--- @param t string|nil  redis type (list/set/hash/zset/string/...)
--- @return string
function M.type_label(t)
  local icon = (t and M.KEY_ICON[t]) or M.KEY_ICON.string
  return icon .. " " .. (t and t ~= "" and t or "string")
end

--- Highlight group for a key type (falls back like the tree does).
--- @param t string|nil
--- @return string
function M.type_hl(t)
  return (t and M.KEY_HL[t]) or M.KEY_HL.string
end

return M
