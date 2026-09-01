--- Redis completion — context detection + item helpers.
---
--- A `.redis` line is `USE <conn>` or `<COMMAND> <arg>...`. This module
--- classifies the cursor position on the current line so the orchestrator
--- knows what to complete:
---
---   - first token position   → Redis command table
---   - after `USE`            → connection names from connections.toml
---   - argument position      → key prefix candidates (SCAN MATCH prefix*)
---
--- Purely heuristic on the text before the cursor — no binary round-trips
--- (the binary never sees file text, EXECUTION-PLAN D1).
local parser = require("poste-redis.parser")

local M = {}

--- Fuzzy match: each character of `pattern` must appear in `text` in order
--- (case-insensitive). Empty pattern matches everything.
--- @param text string
--- @param pattern string
--- @return boolean
function M.fuzzy_match(text, pattern)
  if pattern == "" then return true end
  local ti = 1
  local plower = pattern:lower()
  local tlower = text:lower()
  for pi = 1, #plower do
    local pc = plower:sub(pi, pi)
    local found = false
    while ti <= #tlower do
      if tlower:sub(ti, ti) == pc then
        ti = ti + 1
        found = true
        break
      end
      ti = ti + 1
    end
    if not found then return false end
  end
  return true
end

--- Build completion items from a name list.
--- @param names string[]
--- @param kind number LSP completion item kind
--- @param doc_prefix string|nil
--- @return table[]
function M.make_items(names, kind, doc_prefix)
  local items = {}
  for _, n in ipairs(names or {}) do
    table.insert(items, {
      label = n,
      kind = kind,
      insertText = n,
      documentation = doc_prefix and (doc_prefix .. n) or n,
    })
  end
  return items
end

--- Filter items whose label fuzzy-matches prefix.
--- @param items table[]
--- @param prefix string
--- @return table[]
function M.filter(items, prefix)
  if prefix == "" then return items end
  return vim.tbl_filter(function(i)
    return M.fuzzy_match(i.label, prefix)
  end, items)
end

--- Classify the cursor context for a line.
---
--- @param line_before string text before the cursor on the current line
--- @return table { kind: "command"|"connection"|"key"|"none", prefix: string,
---   command: string|nil }
function M.detect(line_before)
  line_before = line_before or ""
  local trimmed = line_before:match("^%s*(.-)%s*$") or ""
  -- comment / blank → no completion
  if trimmed == "" or trimmed:sub(1, 1) == "#" or trimmed:sub(1, 2) == "--" then
    return { kind = "none", prefix = "" }
  end

  -- Current partial token = text after the last whitespace; a trailing space
  -- means the cursor is between tokens, so the prefix being typed is empty.
  local prefix = line_before:match("(%S+)$") or ""
  -- Inside a quoted string: don't offer key/command completion.
  if prefix:sub(1, 1) == '"' or prefix:sub(1, 1) == "'" then
    return { kind = "none", prefix = "" }
  end

  -- Tokenize the partial line (quote-aware, stops at inline #) to classify
  -- position; the final token is not necessarily the prefix (trailing space).
  local tokens = parser._test.tokenize_line(line_before)
  if #tokens == 0 then return { kind = "none", prefix = "" } end

  -- `USE` directive → connection name after the keyword.
  if tokens[1]:upper() == "USE" then
    return { kind = "connection", prefix = prefix, command = "USE" }
  end

  -- Single token (cursor still in the command name) → command table.
  if #tokens == 1 then
    return { kind = "command", prefix = prefix }
  end

  -- Two or more tokens → argument position → key prefix candidates.
  return {
    kind = "key",
    prefix = prefix,
    command = tokens[1]:upper(),
  }
end

M._test = {
  detect = M.detect,
  fuzzy_match = M.fuzzy_match,
  make_items = M.make_items,
  filter = M.filter,
}

return M
