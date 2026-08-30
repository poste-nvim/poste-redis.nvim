-- Minimal Neovim configuration for running poste-redis tests.
-- Used as -u script (actual vimrc replacement).
-- Sibling deps on rtp: poste.nvim (required). The poste binary itself is NOT
-- needed by unit tests — transport-facing specs stub it.

vim.opt.runtimepath:append(".")
vim.opt.runtimepath:append("../poste.nvim")

-- Dev-loop convenience: prefer a locally built poste binary when present.
if vim.g.poste_binary == nil and vim.fn.filereadable("../poste.nvim/target/release/poste") == 1 then
  vim.g.poste_binary = vim.fn.fnamemodify("../poste.nvim/target/release/poste", ":p")
end

package.path = package.path
  .. ";./tests/?.lua"
  .. ";./tests/?/init.lua"
