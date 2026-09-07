--- `K` docs for `.redis` source buffers.
--- Patterned off poste-http's `util.open_doc_preview` /
--- `http.nav.show_var_value` (vendored here — no poste-http requires):
--- a markdown floating window whose window is tracked, so a second `K` on the
--- same command re-focuses into the already-open popup instead of reopening.
---
--- Content is rendered as `markdown` (syntax block + description + example).
local parser = require("poste-redis.parser")
local docs = require("poste-redis.docs")

local M = {}

-- Track the most recently opened doc float for re-focus on repeated `K`.
local hover_tracker = nil

-- One shared augroup for every doc float's WinClosed autocmd. A per-float
-- group ("PosteRedisDocWin_<win>", one per K popup) died with its autocmd but
-- the group object itself accumulated forever.
local doc_augroup = vim.api.nvim_create_augroup("PosteRedisDocWin", { clear = true })

--- Open a markdown doc preview in a floating window (patterned after
--- poste-http's `util.open_doc_preview`).
--- Returns `float_buf, win, reused` where `reused` is true when an existing
--- tracked window with the same track_key was re-focused instead.
--- @param lines string[]
--- @param opts? { title?: string, track_key?: string, on_close?: fun() }
--- @return number|nil, number|nil, boolean
function M.open_doc_preview(lines, opts)
  opts = opts or {}

  if opts.track_key and hover_tracker and vim.api.nvim_win_is_valid(hover_tracker.win) then
    if hover_tracker.key == opts.track_key then
      vim.api.nvim_set_current_win(hover_tracker.win)
      return hover_tracker.buf, hover_tracker.win, true
    end
    pcall(vim.api.nvim_win_close, hover_tracker.win, true)
    hover_tracker = nil
  end

  local float_buf, win
  local ok
  ok, float_buf, win = pcall(vim.lsp.util.open_floating_preview, lines, "markdown", {
    border = "single",
    title = opts.title,
    title_pos = "left",
    focusable = false,
  })
  if not ok or not float_buf then
    ok, float_buf, win = pcall(vim.lsp.util.open_floating_preview, lines, "markdown", {
      border = "single",
      focusable = false,
    })
    if not ok or not float_buf then
      return nil, nil, false
    end
  end

  if opts.track_key then
    hover_tracker = { win = win, buf = float_buf, key = opts.track_key }
    vim.api.nvim_create_autocmd("WinClosed", {
      group = doc_augroup,
      pattern = tostring(win),
      callback = function() hover_tracker = nil end,
    })
  end

  local function close()
    pcall(vim.api.nvim_win_close, win, true)
    if opts.track_key then hover_tracker = nil end
    if opts.on_close then opts.on_close() end
  end

  vim.keymap.set("n", "q", close, { buffer = float_buf, noremap = true, silent = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = float_buf, noremap = true, silent = true })

  return float_buf, win, false
end

--- Build the markdown lines for a command doc entry.
--- @param cmd string uppercase command name
--- @param entry table { category, syntax, desc, example }
--- @return string[]
function M.build_lines(cmd, entry)
  local lines = {}
  lines[#lines + 1] = "**" .. entry.category .. "**"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "```redis"
  lines[#lines + 1] = entry.syntax
  lines[#lines + 1] = "```"
  if entry.desc and entry.desc ~= "" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = entry.desc
  end
  if entry.example and #entry.example > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "**Example**"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "```redis"
    for _, line in ipairs(entry.example) do
      lines[#lines + 1] = line
    end
    lines[#lines + 1] = "```"
  end
  return lines
end

--- Resolve the command name to document from the cursor position:
--- the current entry's command (first token), falling back to the word under
--- the cursor. Returns nil when nothing on the line is a known command.
--- @param buf number
--- @return string|nil uppercase command name
function M.resolve_command(buf)
  local entry = parser.cursor_entry(buf)
  if entry then
    if entry.kind == "use" then return "USE" end
    if entry.command and entry.command ~= "" then return entry.command end
  end
  local cword = vim.fn.expand("<cword>")
  if cword and cword ~= "" then return cword:upper() end
  return nil
end

--- Show the `K` doc for the command under the cursor. Re-focuses the already
--- open popup for the same command (track_key).
--- @return boolean true if docs were shown
function M.show_command_doc()
  local buf = vim.api.nvim_get_current_buf()
  local cmd = M.resolve_command(buf)
  if not cmd then return false end
  local entry = docs.lookup(cmd)
  if not entry then return false end

  local lines = M.build_lines(cmd, entry)
  M.open_doc_preview(lines, { title = " " .. cmd .. " ", track_key = "cmd:" .. cmd })
  return true
end

M._test = {
  build_lines = M.build_lines,
  resolve_command = M.resolve_command,
}

return M