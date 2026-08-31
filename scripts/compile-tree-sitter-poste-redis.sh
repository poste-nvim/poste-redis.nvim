#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)

grammar_dir="$repo_root/tree-sitter-poste-redis"
src_path="$grammar_dir/src/parser.c"
include_path="$grammar_dir/src"
grammar_name="poste_redis"
so_name="$grammar_name.so"

if [ ! -r "$src_path" ]; then
  printf '%s\n' "missing source: $src_path" >&2
  exit 1
fi

cc_bin=${CC:-}
if [ -z "$cc_bin" ]; then
  if command -v cc >/dev/null 2>&1; then
    cc_bin=cc
  elif command -v gcc >/dev/null 2>&1; then
    cc_bin=gcc
  else
    printf '%s\n' "no compiler found: need cc or gcc" >&2
    exit 1
  fi
fi

if [ -n "${POSTE_REDIS_PARSER_DIR:-}" ]; then
  target_dir=$POSTE_REDIS_PARSER_DIR
elif command -v nvim >/dev/null 2>&1; then
  target_dir=$(nvim --headless --clean '+lua io.write(vim.fn.stdpath("data"))' +q)
  target_dir="$target_dir/site/parser"
else
  target_dir="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/site/parser"
fi

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/poste-redis-ts.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT INT HUP TERM

obj_path="$tmp_dir/$grammar_name.o"
so_path="$tmp_dir/$so_name"

"$cc_bin" -c -I"$include_path" -fPIC -O2 -o "$obj_path" "$src_path"
"$cc_bin" -shared -o "$so_path" "$obj_path"

mkdir -p "$target_dir"
cp "$so_path" "$target_dir/$so_name"

printf '%s\n' "installed $so_name to $target_dir"
