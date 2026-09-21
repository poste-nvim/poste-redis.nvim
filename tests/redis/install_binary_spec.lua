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

describe("poste-redis install ps_literal", function()
  -- Everything after `powershell -Command` is re-parsed as a PowerShell command
  -- line even when it arrives through vim.fn.system's list form, so the paths
  -- the installer builds from stdpath("data") must reach it as literals: a
  -- username with a space or an apostrophe is ordinary on Windows.
  it("keeps a path with a space in one piece", function()
    assert.equals("'C:/Users/Jane Smith/nvim-data/poste/bin'",
      install.ps_literal("C:/Users/Jane Smith/nvim-data/poste/bin"))
  end)

  it("escapes an apostrophe by doubling it, not by ending the literal", function()
    assert.equals("'C:/Users/O''Brien/poste/bin'",
      install.ps_literal("C:/Users/O'Brien/poste/bin"))
  end)

  it("leaves expansion metacharacters inside the literal", function()
    assert.equals("'/tmp/x$(touch pwned)/bin'", install.ps_literal("/tmp/x$(touch pwned)/bin"))
  end)
end)

describe("poste-redis install curl_argv", function()
  -- Both downloads happen inside ensure(), which setup() calls, so they block
  -- Neovim's startup: a run without a ceiling can freeze the editor for as long
  -- as the OS socket timeout, which reads as a hung plugin rather than a failed
  -- download.
  local function has(argv, flag, value)
    for i, v in ipairs(argv) do
      if v == flag and argv[i + 1] == value then return true end
    end
    return false
  end

  it("bounds both the connect and the whole transfer", function()
    local argv = install.curl_argv("-fL", "https://example/poste.tar.gz", "/tmp/poste.tar.gz", 180)
    assert.is_true(has(argv, "--connect-timeout", "10"))
    assert.is_true(has(argv, "--max-time", "180"))
  end)

  it("keeps the flags the caller asked for, silent or not", function()
    -- The checksum fetch is silent, the release download is not.
    assert.equals("-sfL", install.curl_argv("-sfL", "u", "/tmp/o", 20)[2])
    assert.equals("-fL", install.curl_argv("-fL", "u", "/tmp/o", 20)[2])
  end)

  it("passes url and output path as their own argv entries", function()
    -- List form is what keeps a path with a space or a metacharacter out of a
    -- shell; joining them back into one string would reintroduce Round 7's bug.
    local url = "https://example/a b"
    local out = "/tmp/out file$(touch pwned)"
    local argv = install.curl_argv("-fL", url, out, 20)
    assert.equals("curl", argv[1])
    assert.equals(url, argv[7])
    assert.equals("-o", argv[8])
    assert.equals(out, argv[9])
  end)

  it("returns a fresh list per call", function()
    -- The installer calls this twice; a shared table would let one call's
    -- mutation leak into the other's command line.
    local a = install.curl_argv("-fL", "u", "/tmp/a", 20)
    local b = install.curl_argv("-fL", "u", "/tmp/b", 20)
    a[7] = "mutated"
    assert.is_not.equal(a, b)
    assert.equals("u", b[7])
  end)
end)

describe("poste-redis install checksum_matches", function()
  -- The release asset holds sha256sum's lowercase hex; certutil -hashfile
  -- prints the same digest uppercase, which is the only hasher on a Windows
  -- box without Git in PATH.
  local lower = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
  local upper = lower:upper()

  it("accepts the uppercase spelling certutil prints", function()
    assert.is_true(install.checksum_matches(upper, lower))
  end)

  it("accepts two lowercase digests, the sha256sum case", function()
    assert.is_true(install.checksum_matches(lower, lower))
  end)

  it("rejects a digest that differs in one nibble", function()
    local tampered = lower:sub(1, 63) .. (lower:sub(64) == "8" and "9" or "8")
    assert.is_false(install.checksum_matches(tampered, lower))
    assert.is_false(install.checksum_matches(lower, tampered))
  end)

  it("rejects a different digest of the same length", function()
    -- Guards the fix against a compare loose enough to satisfy length alone.
    assert.is_false(install.checksum_matches(string.rep("0", 64), lower))
  end)

  it("rejects a truncated digest", function()
    assert.is_false(install.checksum_matches(upper:sub(1, 63), lower))
  end)
end)
