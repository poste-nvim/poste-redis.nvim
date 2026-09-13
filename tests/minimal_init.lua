-- Minimal Neovim configuration for running poste-redis tests.
-- Used as -u script (actual vimrc replacement).
-- Self-contained since the poste.nvim family dissolution (no poste.nvim on
-- rtp). The poste BINARY is still the family one built in ../poste.nvim —
-- transport-facing specs stub it, so unit tests never execute it; a locally
-- built binary is preferred when present, else a dummy keeps the vendored
-- installer's ensure() hermetic (no download attempt in headless runs).

vim.opt.runtimepath:append(".")

-- Unit specs never need swap files; a crashed headless run used to leave
-- E300 "swap file already exists" residue that broke the next run.
vim.opt.swapfile = false

-- Dev-loop convenience: prefer a locally built poste binary when present.
if vim.g.poste_binary == nil then
  local release = "../poste.nvim/target/release/poste"
  local debug = "../poste.nvim/target/debug/poste"
  local chosen = (vim.fn.filereadable(release) == 1) and release or debug
  if vim.fn.filereadable(chosen) == 1 then
    vim.g.poste_binary = vim.fn.fnamemodify(chosen, ":p")
  else
    local dummy = vim.fn.tempname()
    vim.fn.writefile({ "# dummy poste binary for tests" }, dummy)
    vim.g.poste_binary = dummy
  end
end

-- rtp alone is not enough for require(): Neovim only extends package.path
-- for absolute rtp entries, so mirror the lua/ dirs here explicitly.
local repo = vim.fn.fnamemodify(".", ":p")
package.path = package.path
  .. ";" .. repo .. "lua/?.lua"
  .. ";" .. repo .. "lua/?/init.lua"
  .. ";./tests/?.lua"
  .. ";./tests/?/init.lua"

-- plenary is added to rtp by run.sh after this file; mirror it too.
local plenary = vim.env.PLENARY_PATH
if plenary ~= "" and plenary ~= nil then
  package.path = package.path
    .. ";" .. plenary .. "/lua/?.lua"
    .. ";" .. plenary .. "/lua/?/init.lua"
end
