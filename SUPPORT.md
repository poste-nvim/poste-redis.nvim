# Troubleshooting & Support

**Before opening an issue, work through this page.** Most reports come down to
one of a few causes, and the diagnosis path below pinpoints each in under a
minute. Issues that arrive without `:checkhealth poste-redis` and
`:PosteRedisInfo` output will be asked to provide them before triage.

---

## 1. Run `:checkhealth poste-redis`

This is the single most useful diagnostic. It checks:

- **`poste` binary** — whether one was found and is runnable; the plugin
  shells out to it for every round trip.
- **`redis-exec` subcommand** — the binary must be recent enough to expose
  it; older builds warn here.
- **`connections.toml`** — whether one was discovered and contains
  `dialect = "redis"` sections.
- **tree-sitter `poste_redis` grammar** — highlight/completion support;
  without it a regex syntax fallback is used.
- **blink.cmp / nvim-cmp** — whether completion registered.

```vim
:checkhealth poste-redis
```

To copy the output to the clipboard for pasting into an issue:

```vim
:redir @+ | checkhealth poste-redis | redir END
```

## 2. Common causes

### "poste binary not found"

The plugin never talks to Redis itself — every command goes through the
`poste` binary from [poste.nvim](https://github.com/poste-nvim/poste.nvim).
A usable one (readable **and** executable) is resolved from, in order:
`vim.g.poste_binary`, `$POSTE_BINARY`, the install path
(`stdpath("data")/poste/bin/poste`), a local dev build, then `PATH`. The
binary auto-downloads (SHA256-verified) only when none of those exists.

- Point `vim.g.poste_binary` at your own build to skip the download.
- `:PosteRedisInfo` prints which candidate won and its `from:` label —
  the quickest answer to "why isn't my build being used" (the install
  path outranks `PATH`).

### Commands error with a missing `redis-exec` subcommand

Your binary predates the subcommand. Rebuild poste.nvim
(`cargo build -p poste-cli`) or update the installed release.

### Nothing shows in connections / the browser

`connections.toml` is searched from the current buffer upward. It must
contain a `[section]` with `dialect = "redis"` and a `url` (or
`host`/`port`) — sensitive fields may use `{{ENV_VAR}}` placeholders
resolved from `.env` at runtime (see `.env.example`).

### Completion not triggering

blink.cmp (or nvim-cmp) must be installed; `:checkhealth poste-redis`
reports whether the `poste_redis` source registered. Without the
tree-sitter grammar the plugin falls back to regex syntax — completion
quality degrades but execution still works.

## 3. Before you open an issue

1. `:checkhealth poste-redis` and `:PosteRedisInfo` — paste the full
   output of both (the bug template requires them).
2. The smallest `.redis` buffer content and the relevant
   `connections.toml` section, with credentials redacted.
3. Your Neovim version (`nvim --version | head -1`) and OS.

For questions, usage tips, and config sharing, use
[Discussions](https://github.com/poste-nvim/poste-redis.nvim/discussions)
instead of Issues.
