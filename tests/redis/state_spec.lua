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

  local saved_g, saved_env, saved_cfg, saved_path
  before_each(function()
    saved_g, saved_env, saved_cfg = vim.g.poste_binary, vim.env.POSTE_BINARY, state.config.poste_binary
    saved_path = vim.env.PATH
  end)
  after_each(function()
    if saved_g == nil then vim.cmd("unlet! g:poste_binary") else vim.g.poste_binary = saved_g end
    vim.env.POSTE_BINARY = saved_env
    state.config.poste_binary = saved_cfg
    vim.env.PATH = saved_path
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

  -- The second return is what :PosteRedisInfo and checkhealth print. Five
  -- candidates can win and the installed release outranks $PATH, so "why is my
  -- own build not being used" has no answer without the name.
  it("names the candidate that answered", function()
    -- The install path is pinned to a missing file first: a release downloaded
    -- into the test XDG dir by an earlier run would otherwise outrank the
    -- candidates asserted below.
    state.config.poste_binary = vim.fn.tempname() .. "-missing"
    vim.g.poste_binary = stub_binary(tonumber("755", 8))
    local g_only = { state.find_poste_binary() }
    assert.equals("g:poste_binary", g_only[2])
    vim.cmd("unlet! g:poste_binary")
    vim.env.POSTE_BINARY = stub_binary(tonumber("755", 8))
    assert.equals("$POSTE_BINARY", ({ state.find_poste_binary() })[2])
    vim.env.POSTE_BINARY = nil
    local exe = stub_binary(tonumber("755", 8))
    state.config.poste_binary = exe
    local found = { state.find_poste_binary() }
    assert.equals("installed release", found[2])
    assert.equals(vim.fn.fnamemodify(exe, ":p"), found[1])
  end)

  it("names $PATH when the binary comes from there", function()
    vim.cmd("unlet! g:poste_binary")
    vim.env.POSTE_BINARY = nil
    state.config.poste_binary = vim.fn.tempname() .. "-missing"
    local dir = vim.fn.tempname()
    assert.truthy(vim.fn.mkdir(dir, "p"))
    files[#files + 1] = dir
    local p = dir .. "/poste"
    vim.fn.writefile({ "#!/bin/sh", "echo poste 1.0.0" }, p)
    assert.truthy(uv.fs_chmod(p, tonumber("755", 8)))
    files[#files + 1] = p
    vim.env.PATH = dir
    local found = { state.find_poste_binary() }
    assert.equals("$PATH", found[2])
    assert.equals("poste", vim.fn.fnamemodify(found[1], ":t"))
  end)

  it("returns no source with no path when nothing is usable", function()
    vim.cmd("unlet! g:poste_binary")
    vim.env.POSTE_BINARY = nil
    state.config.poste_binary = vim.fn.tempname() .. "-missing"
    -- No dev build in this repo's CWD or next to the plugin, and nothing on PATH.
    vim.env.PATH = vim.fn.tempname()
    local path, source = state.find_poste_binary()
    assert.is_nil(path)
    assert.is_nil(source)
  end)
end)

--- The installer writes `poste.exe` on Windows and cargo builds `poste.exe`
--- into target/{debug,release}/, while every candidate this lookup offers is
--- spelled without the extension: resolving only the bare name made startup
--- download a release it could never find again, so it re-downloaded on every
--- launch and `:checkhealth` reported no binary.
describe("poste-redis.state binary resolution on Windows", function()
  local dir
  local saved

  local function write_exe(p)
    vim.fn.writefile({ "#!/bin/sh", "echo poste 1.0.0" }, p)
    assert.truthy(uv.fs_chmod(p, tonumber("755", 8)))
    return p
  end

  before_each(function()
    dir = vim.fn.tempname()
    assert.truthy(vim.fn.mkdir(dir, "p"))
    saved = {
      g = vim.g.poste_binary,
      env = vim.env.POSTE_BINARY,
      path = vim.env.PATH,
      cfg = state.config.poste_binary,
      is_windows = state.is_windows,
    }
    vim.cmd("unlet! g:poste_binary")
    vim.env.POSTE_BINARY = nil
    -- An empty PATH and a missing install path: only the candidate under test
    -- may answer, and a release left in the test XDG dir by an earlier run
    -- must not outrank it.
    vim.env.PATH = dir .. "/empty"
    assert.truthy(vim.fn.mkdir(dir .. "/empty", "p"))
    state.config.poste_binary = dir .. "/not-configured"
  end)
  after_each(function()
    state.is_windows = saved.is_windows
    state.config.poste_binary = saved.cfg
    if saved.g == nil then vim.cmd("unlet! g:poste_binary") else vim.g.poste_binary = saved.g end
    vim.env.POSTE_BINARY = saved.env
    vim.env.PATH = saved.path
    vim.fn.delete(dir, "rf")
  end)

  it("finds the .exe the installer wrote", function()
    state.is_windows = true
    local exe = write_exe(dir .. "/poste.exe")
    state.config.poste_binary = dir .. "/poste"
    local path, source = state.find_poste_binary()
    assert.equals(vim.fn.fnamemodify(exe, ":p"), path)
    assert.equals("installed release", source)
  end)

  it("adds the .exe to a g:poste_binary spelled without one", function()
    -- Configuring the extension-less name is what the docs tell Windows users
    -- to type, and the file beside it is the one that runs.
    state.is_windows = true
    local exe = write_exe(dir .. "/poste.exe")
    vim.g.poste_binary = dir .. "/poste"
    local path, source = state.find_poste_binary()
    assert.equals(vim.fn.fnamemodify(exe, ":p"), path)
    assert.equals("g:poste_binary", source)
  end)

  it("prefers the exact candidate over the .exe guess", function()
    state.is_windows = true
    local exact = write_exe(dir .. "/poste")
    write_exe(dir .. "/poste.exe")
    state.config.poste_binary = dir .. "/poste"
    assert.equals(vim.fn.fnamemodify(exact, ":p"), state.find_poste_binary())
  end)

  it("does not run a .exe off Windows", function()
    -- POSIX has no extension rule: a file named poste.exe there is not the
    -- `poste` the user asked for, and picking it would execute the wrong thing.
    state.is_windows = false
    write_exe(dir .. "/poste.exe")
    state.config.poste_binary = dir .. "/poste"
    assert.is_nil(state.find_poste_binary())
  end)
end)

describe("poste-redis.state poste_version", function()
  local dirs = {}
  after_each(function()
    for _, d in ipairs(dirs) do vim.fn.delete(d, "rf") end
    dirs = {}
  end)

  it("answers nil when there is no binary to ask", function()
    assert.is_nil(state.poste_version(vim.fn.tempname() .. "-missing"))
  end)

  it("reads the version without a shell, from a path that would break one", function()
    -- The path has a space and a quote: an io.popen interpolation would run a
    -- different command, vim.system cannot.
    local dir = vim.fn.tempname() .. '/a b"c'
    assert.equals(1, vim.fn.mkdir(dir, "p"))
    local p = dir .. "/poste"
    vim.fn.writefile({ "#!/bin/sh", "echo 'poste 9.9.9 (test)'" }, p)
    assert.truthy(uv.fs_chmod(p, tonumber("755", 8)))
    dirs[#dirs + 1] = dir
    assert.equals("poste 9.9.9 (test)", state.poste_version(p))
  end)
end)
