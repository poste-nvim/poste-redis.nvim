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
timeout "${RUN_ONE_TIMEOUT:-240}" nvim --headless \
  -u tests/minimal_init.lua \
  -c "set rtp+=$PLENARY_PATH" \
  -c "set rtp+=." \
  -c "runtime plugin/plenary.vim" \
  -c "PlenaryBustedFile $F"
