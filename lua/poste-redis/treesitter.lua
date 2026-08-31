--- Tree-sitter grammar registration for `.redis` (M2 P1-6).
---
--- Pattern mirrors poste-http: the grammar lives in tree-sitter-poste-redis/
--- and is compiled into stdpath("data")/site/parser by install.lua (which
--- needs a C compiler). Without a compiler (or before compilation) the M1
--- regex syntax (syntax/poste_redis.vim) stays active — the two never fight:
--- tree-sitter highlights run only when the parser .so is loadable.

local M = {}

local GRAMMAR_NAME = "poste_redis"

--- Is the compiled parser loadable? Checks for the compiled .so in the
--- install location (stdpath data/site/parser) or any rtp parser dir —
--- `language.add`/`treesitter.start` silently accept unknown names on some
--- nvim versions, so file presence is the reliable probe.
--- @return boolean
function M.parser_available()
  -- 1) install.lua's output location
  local so = vim.fn.stdpath("data") .. "/site/parser/" .. GRAMMAR_NAME .. ".so"
  if vim.fn.filereadable(so) == 1 then return true end
  -- 2) any runtimepath parser/ dir (nvim's standard lookup)
  for _, rtp in ipairs(vim.api.nvim_list_runtime_paths()) do
    if vim.fn.filereadable(rtp .. "/parser/" .. GRAMMAR_NAME .. ".so") == 1 then
      return true
    end
  end
  return false
end

--- Enable tree-sitter highlighting for the poste_redis filetype.
--- No-op when the parser isn't compiled (regex fallback stays in effect).
--- @param buf number|nil
function M.enable(buf)
  if not M.parser_available() then
    return false
  end
  local ok, err = pcall(vim.treesitter.language.register, GRAMMAR_NAME, "poste_redis")
  if not ok then
    vim.notify("tree-sitter register failed: " .. tostring(err), vim.log.levels.WARN)
    return false
  end
  -- Keep the legacy syntax file active as a fallback. The grammar is only a
  -- highlighter, and some example files use continuation/indent forms that the
  -- tree-sitter query does not model yet.
  pcall(vim.treesitter.start, buf or 0, GRAMMAR_NAME)
  return true
end

--- Disable tree-sitter (fall back to regex syntax) for the filetype.
--- @param buf number|nil
function M.disable(buf)
  pcall(vim.treesitter.stop, buf or 0)
  pcall(vim.api.nvim_set_option_value, "syntax", "poste_redis", { buf = buf or 0 })
end

--- Try to compile + enable; used by setup (best-effort, never blocks).
function M.ensure()
  local install = require("poste-redis.install")
  install.ensure_parsers()
  M.enable()
end

M._test = {
  GRAMMAR_NAME = GRAMMAR_NAME,
}

return M
