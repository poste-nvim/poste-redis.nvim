--- install_binary spec — the startup guarantee: `ensure()` returns a binary the
--- transport can spawn, and only goes to the network when nothing usable
--- exists. The candidate walk itself is state.find_poste_binary's (see
--- state_spec.lua); these cases pin that ensure() delegates to it instead of
--- carrying a second, drifted copy of the rule.
local install = require("poste-redis.install_binary")
local state = require("poste-redis.state")
local uv = vim.uv or vim.loop

describe("poste-redis install ensure", function()
  local created = {}
  local empty_dir

  local function make(path, mode)
    vim.fn.writefile({ "#!/bin/sh", "echo poste 1.0.0" }, path)
    assert.truthy(uv.fs_chmod(path, mode))
    created[#created + 1] = path
    return path
  end

  local download_calls
  local saved = {}
  before_each(function()
    empty_dir = vim.fn.tempname()
    assert.truthy(vim.fn.mkdir(empty_dir, "p"))
    -- An empty PATH stops the lookup's last arm from answering with a binary
    -- installed on this machine; each case supplies its own candidates.
    saved = {
      g = vim.g.poste_binary,
      env = vim.env.POSTE_BINARY,
      path = vim.env.PATH,
      cfg = state.config.poste_binary,
      download = install.download,
    }
    vim.env.PATH = empty_dir
    state.config.poste_binary = empty_dir .. "/not-configured"
    download_calls = 0
    install.download = function()
      download_calls = download_calls + 1
      return false
    end
  end)
  after_each(function()
    if saved.g == nil then vim.cmd("unlet! g:poste_binary") else vim.g.poste_binary = saved.g end
    vim.env.POSTE_BINARY = saved.env
    vim.env.PATH = saved.path
    state.config.poste_binary = saved.cfg
    install.download = saved.download
    for _, p in ipairs(created) do vim.fn.delete(p) end
    created = {}
    vim.fn.delete(empty_dir, "rf")
  end)

  it("returns the binary state.find_poste_binary resolves, without downloading", function()
    local exe = make(vim.fn.tempname(), tonumber("755", 8))
    vim.g.poste_binary = exe
    assert.equals(vim.fn.fnamemodify(exe, ":p"), install.ensure())
    assert.equals(0, download_calls)
  end)

  it("refuses a readable but not executable override", function()
    -- The old copy of the rule returned this path and skipped the download
    -- that would have produced a binary the transport can spawn.
    local inert = make(vim.fn.tempname(), tonumber("644", 8))
    local runnable = make(vim.fn.tempname(), tonumber("755", 8))
    vim.g.poste_binary = inert
    vim.env.POSTE_BINARY = runnable
    assert.equals(vim.fn.fnamemodify(runnable, ":p"), install.ensure())
    assert.equals(0, download_calls)
  end)

  it("uses a binary on $PATH instead of downloading a release", function()
    vim.cmd("unlet! g:poste_binary")
    vim.env.POSTE_BINARY = nil
    make(empty_dir .. "/poste", tonumber("755", 8))
    local found = install.ensure()
    assert.is_not_nil(found)
    assert.equals("poste", vim.fn.fnamemodify(found, ":t"))
    assert.equals(empty_dir, vim.fn.fnamemodify(found, ":h"))
    assert.equals(0, download_calls)
  end)

  it("downloads when nothing usable is anywhere", function()
    vim.cmd("unlet! g:poste_binary")
    vim.env.POSTE_BINARY = nil
    assert.is_nil(install.ensure())
    assert.equals(1, download_calls)
  end)
end)
