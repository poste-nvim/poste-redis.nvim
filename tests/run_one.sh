#!/bin/bash
# Targeted single-file run (./tests/run.sh ignores args and runs the whole
# directory). Usage: ./tests/run_one.sh tests/redis/history_spec.lua
set -e
cd "$(dirname "$0")/.."
F="${1:?spec file}"
if [ -z "$PLENARY_PATH" ]; then
  for dir in \
    "$HOME/.local/share/nvim/lazy/plenary.nvim" \
    "$HOME/.local/share/nvim/site/pack/packer/start/plenary.nvim" \
    "$HOME/.config/nvim/plugged/plenary.nvim" \
    "$HOME/.config/nvim/lazy/plenary.nvim"; do
    if [ -d "$dir" ]; then PLENARY_PATH="$dir"; break; fi
  done
fi
[ -d "$PLENARY_PATH" ] || { echo "Error: plenary.nvim not found (set PLENARY_PATH)."; exit 1; }
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/tmp/poste-redis-test-cache}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-/tmp/poste-redis-test-data}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-/tmp/poste-redis-test-state}"
# `busted.run` directly instead of :PlenaryBustedFile: that command takes one
# argument, so it cannot forward `minimal_init` and the process Plenary spawns
# runs `--noplugin -u <minimal_init>` — while the targeted runner used to load
# the developer's own config. A ColorScheme autocmd from that config fires
# inside specs that stub nvim_set_hl and count the calls, so the gate is green
# and the same file fails per spec.
# `--noplugin` completes the equality: tests/minimal_init.lua appends "." to
# rtp, so without the flag Neovim also sources this repo's plugin/poste-redis.lua
# — i.e. setup({}) and the binary installer's ensure() run before every spec,
# and a spec that replaces `package.loaded[...]` at file scope binds modules
# that were already loaded. No per-file count moved here (641 with and without
# the flag), but in poste-db the same preload fails 38 stub-order cases.
timeout "${RUN_ONE_TIMEOUT:-240}" nvim --headless --noplugin \
  -u tests/minimal_init.lua \
  -c "set rtp+=$PLENARY_PATH" \
  -c "set rtp+=." \
  -c "runtime plugin/plenary.vim" \
  -c "lua require('plenary.busted').run('$F')"
