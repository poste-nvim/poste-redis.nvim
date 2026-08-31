--- treesitter spec — grammar registration + regex fallback (M2 P1-6).
--- The parser may or may not be compiled depending on the environment
--- (install.ensure_parsers compiles it when cc is present). Both paths must
--- behave: parser_available reflects reality, enable never throws, and the
--- regex fallback survives either way.
local treesitter = require("poste-redis.treesitter")

describe("poste-redis treesitter", function()
  it("parser_available returns a boolean and never throws", function()
    local ok, avail = pcall(treesitter.parser_available)
    assert.is_true(ok)
    assert.is_true(type(avail) == "boolean")
  end)

  it("enable is a safe call with or without a parser", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(buf, "filetype", "poste_redis")
    local ok, result = pcall(treesitter.enable, buf)
    assert.is_true(ok)          -- never throws
    assert.is_true(type(result) == "boolean")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("install reports the grammar path and compiler probe", function()
    local install = require("poste-redis.install")
    local g = install._test.GRAMMAR
    assert.equals("poste_redis", g.name)
    assert.equals("tree-sitter-poste-redis", g.dir)
    assert.equals("src/parser.c", g.src)
    assert.equals("poste_redis.so", g.so)
    -- cc() must be a callable (returns string|nil, never throws)
    local ok, c = pcall(install._test.cc)
    assert.is_true(ok)
    assert.is_true(type(c) == "string" or c == nil)
  end)

  it("ensure_parsers is a silent no-op without a compiler or sources", function()
    -- must not throw in either case
    assert.has_no.errors(function()
      treesitter.ensure()
    end)
  end)

  it("tree-sitter parses the example files cleanly", function()
    local install = require("poste-redis.install")
    install.ensure_parsers()

    local so = install._test.parser_dir() .. "/poste_redis.so"
    if vim.fn.filereadable(so) ~= 1 or vim.fn.executable("tree-sitter") ~= 1 then
      pending("tree-sitter CLI or compiled parser unavailable")
      return
    end

    for _, path in ipairs({ "examples/demo.redis", "examples/parser_edges.redis" }) do
      local out = vim.fn.system({
        "tree-sitter",
        "parse",
        "-l",
        so,
        "--lang-name",
        "poste_redis",
        "-q",
        path,
      })
      assert.equals(0, vim.v.shell_error, out)
    end
  end)
end)
