# poste-redis.nvim

Redis for Neovim in the [Poste](https://github.com/beyondlex/poste.nvim) plugin family —
write Redis commands in a `.redis` buffer, hit `<CR>`, and read the results in a result
panel. A key browser, value viewer and executable history are included.

## Install

With lazy.nvim:

```lua
{
  "beyondlex/poste-redis.nvim",
  opts = {},
}
```

The plugin shells out to the `poste` binary: a usable one (readable **and**
executable) is resolved from `vim.g.poste_binary`, `$POSTE_BINARY`, the install
path, a local dev build or `PATH`, and only downloaded from poste.nvim releases
on first setup when none of those exists — point `vim.g.poste_binary` at your
own build to skip the download. `:checkhealth poste-redis` and `:PosteRedisInfo`
print which of those candidates won, since the install path outranks `PATH` and
a stray download would otherwise mask your own build silently.

Connections live in the project `connections.toml`:

```toml
[my-redis]
dialect = "redis"
url = "redis://:{{REDIS_PASS}}@127.0.0.1:6379/0"
```

`{{var}}` refs resolve from the OS env, `.env` and `env.json` (OS env wins).

## Usage

```redis
USE my-redis
SELECT 3
SET session:abc "token" EX 3600
GET session:abc
```

- `<CR>` executes the command under the cursor (or a visual selection);
  `:PosteRedisRunFile` runs the whole file. `USE` splits a file into
  per-connection batches that run sequentially; the `SELECT` above a
  selection is re-applied so single runs land on the right db.
- Results render in a bottom panel: scalars as text, collections
  (list/set/hash/zset) as a sortable grid with a frozen header, cell
  navigation, search, paging and yank. `i`/`o`/`dd` edit cells/rows back to
  Redis (with stale-cell guards); `r` re-runs the tab's command; `gd` jumps
  to the tab's key in the browser; `E` exports the whole grid to a file
  (CSV / TSV / JSON).
- `<Esc>` cancels an in-flight execution. Dangerous commands (`FLUSHALL`,
  `FLUSHDB`, `SHUTDOWN`, `CONFIG`) are flagged in the panel and, on `<CR>` or
  a file run, ask for an explicit yes before anything is dispatched
  (`confirm_commands = false` to opt out).

## Key browser

`:PosteRedisBrowser` opens a side split:

- Lazy `SCAN` loading — db expand costs one page, groups load on demand;
  flat / flatten / nested (`:`-segment folders) layouts via
  `:PosteRedisBrowserView`.
- `<leader>/` filters keys by substring; `<Space>` switches db; `o` switches
  connection; `d`/`D` delete keys/prefixes (multi-select with `<Tab>`),
  `t` TTL (on a selection: one prompt for every selected key), `R` rename,
  `i` info, `y` yank.
- `<CR>` on a key opens a paginated value viewer (HSCAN/SSCAN/ZSCAN/LRANGE
  pages); truncated strings load fully with `F`.

## History & docs

- `<leader>rh` opens the history sidebar beside the panel: j/k previews the
  snapshot live, `<CR>` restores it, `y` yanks an executable form.
- `K` on a Redis command (e.g. `HSET`, `RPUSH`) opens a markdown doc — syntax
  plus examples; pressing `K` again focuses the popup. Run `:PosteRedisInfo`
  to inspect the active connection.
- `<C-Space>` completes commands, keys and subcommands (blink.cmp source;
  works out of the box when blink is installed).

`requirements.md` and `EXECUTION-PLAN.md` are the historical M1/M2 specs
(both milestones shipped); the
[doc site](https://github.com/beyondlex/doc-poste) documents current behavior.

## License

MIT
