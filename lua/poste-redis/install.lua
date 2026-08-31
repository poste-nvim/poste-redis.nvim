--- Compile the poste_redis tree-sitter parser (M2 P1-6).
---
--- Mirrors poste-http/install.lua: compiles tree-sitter-poste-redis/src/parser.c
--- into stdpath("data")/site/parser/poste_redis.so. Needs a C compiler
--- (cc/gcc); when absent, health reports it and regex syntax stays active.

local M = {}

local GRAMMAR = {
  name = "poste_redis",
  dir = "tree-sitter-poste-redis",
  src = "src/parser.c",
  so = "poste_redis.so",
}

local function plugin_root()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(src, ":h:h:h")
end

local function parser_dir()
  return vim.fn.stdpath("data") .. "/site/parser"
end

local function cc()
  if vim.fn.executable("cc") == 1 then return "cc" end
  if vim.fn.executable("gcc") == 1 then return "gcc" end
  return nil
end

--- @return boolean need, string|nil reason
local function needs_compile(grammar_dir, so_path)
  local parser_c = grammar_dir .. "/src/parser.c"
  if vim.fn.filereadable(parser_c) ~= 1 then
    return false, "source not found: " .. parser_c
  end
  if vim.fn.filereadable(so_path) ~= 1 then
    return true
  end
  local src_mtime = vim.fn.getftime(parser_c)
  local so_mtime = vim.fn.getftime(so_path)
  return src_mtime > so_mtime
end

--- @return boolean ok, string|nil reason
function M.compile_one(grammar)
  grammar = grammar or GRAMMAR
  local root = plugin_root()
  local grammar_dir = root .. "/" .. grammar.dir
  local parser_dir_path = parser_dir()
  local so_path = parser_dir_path .. "/" .. grammar.so

  local need, reason = needs_compile(grammar_dir, so_path)
  if not need then
    return false, reason
  end

  local c = cc()
  if not c then
    return false, "C compiler not found (cc/gcc)"
  end

  if vim.fn.isdirectory(parser_dir_path) ~= 1 then
    vim.fn.mkdir(parser_dir_path, "p")
  end

  local src_path = grammar_dir .. "/" .. grammar.src
  local obj_path = parser_dir_path .. "/" .. grammar.name .. ".o"
  local include_path = grammar_dir .. "/src"
  local cmd_obj = string.format("%s -c -I%s -fPIC -O2 -o %s %s", c, include_path, obj_path, src_path)
  local cmd_so = string.format("%s -shared -o %s %s", c, so_path, obj_path)

  local out = vim.fn.system(cmd_obj)
  if vim.v.shell_error ~= 0 then
    pcall(vim.fn.delete, obj_path)
    return false, "compile failed: " .. (out or "")
  end
  out = vim.fn.system(cmd_so)
  pcall(vim.fn.delete, obj_path)
  if vim.v.shell_error ~= 0 then
    pcall(vim.fn.delete, so_path)
    return false, "link failed: " .. (out or "")
  end
  return true
end

--- Best-effort: compile the parser if a compiler exists. Silent no-op
--- otherwise (health reports the missing compiler).
function M.ensure_parsers()
  if not cc() then return end
  local ok, reason = M.compile_one(GRAMMAR)
  if not ok and reason and reason:find("source not found") then
    -- grammar sources not vendored yet — not an error, just unavailable
    return
  end
end

M._test = {
  GRAMMAR = GRAMMAR,
  parser_dir = parser_dir,
  cc = cc,
}

return M
