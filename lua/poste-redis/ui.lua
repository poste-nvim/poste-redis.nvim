--- Shared centered modal float. The result preview, the source-buffer help
--- and the history list are all "scratch buffer + rounded border + centered,
--- q/Esc closes"; they differ only in sizing, title and extra keymaps, which
--- this helper takes as options.
local M = {}

--- Lay out keymap-help rows for the g? floats: every description starts at
--- the same column (the widest key decides it), keys get their own highlight
--- span, section headers and prose notes are highlighted whole-line.
--- Row shapes:
---   { header = s }              section title (PosteRedisHelpHeader)
---   { blank = true }            spacer line
---   { note = s }                dimmed prose (PosteRedisHelpNote)
---   { key = s, desc = s }       one keymap row (key → PosteRedisHelpKey)
--- Spans carry byte columns and 0-based rows — straight into
--- nvim_buf_set_extmark. Display widths come from nvim_strwidth so a custom
--- multibyte keymap still aligns; span columns stay in bytes.
--- @param rows table[]
--- @return string[] lines, table[] spans
function M.help_layout(rows)
  local key_width = 0
  for _, r in ipairs(rows) do
    if r.key then
      key_width = math.max(key_width, vim.api.nvim_strwidth(r.key))
    end
  end
  local lines, spans = {}, {}
  for i, r in ipairs(rows) do
    local row = i - 1
    if r.key then
      local pad = string.rep(" ", key_width - vim.api.nvim_strwidth(r.key))
      lines[#lines + 1] = "  " .. r.key .. pad .. "  " .. (r.desc or "")
      spans[#spans + 1] =
        { row = row, col = 2, end_col = 2 + #r.key, group = "PosteRedisHelpKey" }
    elseif r.header then
      lines[#lines + 1] = r.header
      spans[#spans + 1] =
        { row = row, col = 0, end_col = #r.header, group = "PosteRedisHelpHeader" }
    elseif r.note then
      lines[#lines + 1] = r.note
      spans[#spans + 1] =
        { row = row, col = 0, end_col = #r.note, group = "PosteRedisHelpNote" }
    else
      lines[#lines + 1] = ""
    end
  end
  return lines, spans
end

--- Open the g? help float for `rows` (shapes above): laid out, sized from the
--- content (not a fixed 72), rendered, and highlighted in one step.
--- @param rows table[]
--- @param opts table|nil { title = string }
--- @return number win, number buf
function M.help_float(rows, opts)
  opts = opts or {}
  local lines, spans = M.help_layout(rows)
  local content = 0
  for _, l in ipairs(lines) do
    content = math.max(content, vim.api.nvim_strwidth(l))
  end
  local w, b = M.centered_float(lines, {
    title = opts.title,
    width = math.min(content + 2, vim.o.columns - 4),
    height = math.min(#lines + 2, vim.o.lines - 4),
  })
  local ns = vim.api.nvim_create_namespace("PosteRedisHelp")
  for _, s in ipairs(spans) do
    vim.api.nvim_buf_set_extmark(b, ns, s.row, s.col,
      { end_col = s.end_col, hl_group = s.group })
  end
  return w, b
end

--- Open a centered float showing `lines`.
--- @param lines string[]
--- @param opts table|nil {
---   title = string|nil,       float title (default: no title text)
---   width = number|nil,       target width  (default: editor columns - 4)
---   height = number|nil,      target height (default: #lines + 2)
---   cursorline = boolean|nil, highlight the cursor line (list-like floats)
---   filetype = string|nil,    buffer filetype (e.g. "json")
---   keymaps = table|nil,      extra normal-mode bindings { { key, fn }, ... }
---                             applied after the default q/Esc close
--- }
--- @return number win, number buf
function M.centered_float(lines, opts)
  opts = opts or {}
  local width = math.max(1, math.min(opts.width or (vim.o.columns - 4), vim.o.columns - 2))
  local height = math.max(1, math.min(opts.height or (#lines + 2), vim.o.lines - 4))

  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = b })
  -- one buffer line per item: nvim_buf_set_lines rejects an item containing
  -- a newline (E5108 "replacement string item contains newlines"), so a
  -- caller embedding "\n" in a help line would take the whole float down —
  -- split instead, the rendering intent is identical.
  local flat = {}
  for _, line in ipairs(lines or {}) do
    for _, part in ipairs(vim.split(tostring(line), "\n", { plain = true })) do
      flat[#flat + 1] = part
    end
  end
  vim.api.nvim_buf_set_lines(b, 0, -1, false, flat)
  vim.api.nvim_set_option_value("modifiable", false, { buf = b })
  if opts.filetype then
    vim.api.nvim_set_option_value("filetype", opts.filetype, { buf = b })
  end

  local w = vim.api.nvim_open_win(b, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = opts.title or " ",
    title_pos = "center",
  })
  if opts.cursorline then
    vim.api.nvim_set_option_value("cursorline", true, { win = w })
  end

  local km = { buffer = b, noremap = true, silent = true }
  local close = function() pcall(vim.api.nvim_win_close, w, true) end
  vim.keymap.set("n", "q", close, km)
  vim.keymap.set("n", "<Esc>", close, km)
  for _, m in ipairs(opts.keymaps or {}) do
    vim.keymap.set("n", m.key, m.fn, km)
  end

  return w, b
end

return M
