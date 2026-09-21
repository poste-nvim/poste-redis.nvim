--- state spec — the `poste` binary lookup. Every transport-facing module
--- (runner, cli, health) spawns what `find_poste_binary` returns, so the
--- order and the "runnable" test are the contract under test here.
local state = require("poste-redis.state")
local uv = vim.uv or vim.loop

describe("poste-redis.state binary resolution", function()
  local files = {}
  --- Write a file with an explicit mode, tracked for cleanup.
  local function stub_binary(mode)
    local p = vim.fn.tempname()
    vim.fn.writefile({ "#!/bin/sh", "echo poste 1.0.0" }, p)
    assert.truthy(uv.fs_chmod(p, mode))
    files[#files + 1] = p
    return p
  end

  local saved_g, saved_env, saved_cfg
  before_each(function()
    saved_g, saved_env, saved_cfg = vim.g.poste_binary, vim.env.POSTE_BINARY, state.config.poste_binary
  end)
  after_each(function()
    if saved_g == nil then vim.cmd("unlet! g:poste_binary") else vim.g.poste_binary = saved_g end
    vim.env.POSTE_BINARY = saved_env
    state.config.poste_binary = saved_cfg
    for _, p in ipairs(files) do vim.fn.delete(p) end
    files = {}
  end)

  it("ignores a candidate that is readable but not executable", function()
    -- A downloaded or copied binary without the exec bit used to win over a
    -- working $POSTE_BINARY here, then fail at spawn with an opaque error.
    local inert = stub_binary(tonumber("644", 8))
    vim.g.poste_binary = inert
    state.config.poste_binary = inert
    assert.is_not.equal(vim.fn.fnamemodify(inert, ":p"), state.find_poste_binary())
  end)

  it("prefers an executable vim.g.poste_binary", function()
    local exe = stub_binary(tonumber("755", 8))
    vim.g.poste_binary = exe
    assert.equals(vim.fn.fnamemodify(exe, ":p"), state.find_poste_binary())
  end)

  it("uses $POSTE_BINARY when no config variable points at a runnable file", function()
    -- The busted child processes plenary spawns start without `-u
    -- minimal_init.lua`, so a `vim.g` set there never reaches them; the
    -- environment is the only channel left.
    vim.cmd("unlet! g:poste_binary")
    state.config.poste_binary = vim.fn.tempname() .. "-missing"
    local exe = stub_binary(tonumber("755", 8))
    vim.env.POSTE_BINARY = exe
    assert.equals(vim.fn.fnamemodify(exe, ":p"), state.find_poste_binary())
  end)

  it("ignores $POSTE_BINARY when it points at a non-executable file", function()
    vim.cmd("unlet! g:poste_binary")
    state.config.poste_binary = vim.fn.tempname() .. "-missing"
    vim.env.POSTE_BINARY = stub_binary(tonumber("644", 8))
    -- Must not return the inert env path: either a PATH `poste` or nothing.
    assert.is_not.equal(vim.fn.fnamemodify(vim.env.POSTE_BINARY, ":p"), state.find_poste_binary())
  end)
end)
