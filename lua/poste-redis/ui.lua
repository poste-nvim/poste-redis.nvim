--- Shared centered modal float. The result preview, the source-buffer help
--- and the history list are all "scratch buffer + rounded border + centered,
--- q/Esc closes"; they differ only in sizing, title and extra keymaps, which
--- this helper takes as options.
local M = {}

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
