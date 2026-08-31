---
name: redis
description: >
  Redis execution in the Poste plugin family: .redis file parsing, connection
  resolution, poste redis-exec transport, result rendering, and M1 acceptance.
  Use when working on poste-redis.nvim (not SQL/HTTP). Loads ZERO poste-db /
  poste-http files.
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
metadata:
  trigger: redis|\.redis|poste_redis|USE my-redis|redis-exec|HGETALL|connections.toml
---

# Redis — Agent Skill

Only load files listed below. Do NOT read `lua/poste-db/`, `lua/poste-http/`, or any
SQL/HTTP-specific files unless the task explicitly crosses protocols.

## File Index

### Shared (load always)

| File | Why |
|------|-----|
| `AGENTS.md` | Architecture, conventions, Lua pitfalls |
| `requirements.md` | Product spec (P0–P3, value shapes, naming) |
| `EXECUTION-PLAN.md` | M1 work breakdown, decisions D1–D6, acceptance §8 |
| `lua/poste/state.lua` | `find_poste_binary`, shared config |
| `lua/poste/cli.lua` | `run` / `run_async` / `run_json` wrappers |
| `lua/poste/select.lua` | Connection picker |
| `lua/poste/indicators.lua` | Spinner / ✓ / ✘ indicators |

### Redis Lua (`lua/poste-redis/`)

| File | Role |
|------|------|
| `parser.lua` | The only parser (D1): continuations, quote-aware comments, USE |
| `connections.lua` | connections.toml → redis:// URL (url/field forms, `{{var}}`) |
| `exec_run.lua` | Transport: run_async / run_file_async / run_sync, stale-guard |
| `runner.lua` | `<CR>` entry: exec_run → buffer → history |
| `format.lua` | Value rendering + error + preview_json |
| `buffer.lua` | M1 result panel (tabs, K preview) |
| `history.lua` | In-memory history + float |
| `toml.lua` | **Vendored** from poste-db — don't edit without syncing source |
| `config.lua` / `state.lua` / `constants.lua` / `util.lua` | defaults / context / dims & blacklist / helpers |

### Rust (in `../poste.nvim`)

| File | Role |
|------|------|
| `crates/poste-exec/src/redis_executor.rs` | execute_commands_with, redis_value_to_json |
| `crates/poste-cli/src/redis_exec.rs` | `poste redis-exec` NDJSON contract |

## Contract cheat-sheet

- stdin: `{"connection":"redis://...","commands":[["GET","k"]]}`
- stdout events: `progress` / `result` (status `"error"` + `error` keeps going) / `summary`
- value shapes: `nil|integer|string|binary|list|set|hash|zset|stream|unknown`, with
  `len`/`truncated` and hash `entries` pairs; binary → hex `preview` + `bytes`
- Lua parses `.redis`; Rust never sees file text (D1)

## Testing

```bash
./tests/run.sh                          # plenary, isolated XDG
REDIS_TEST_URL=redis://127.0.0.1:16479/0 ./tests/run.sh   # + live redis e2e
cd ../poste.nvim && cargo test -p poste-exec -p poste-cli
```

Playground: `playground/docker-compose.yml` starts redis:7 on 127.0.0.1:16479.

## Pitfalls

- Callbacks: `guarded(seq, cb, ...)()` — never `guarded(...)(...)`
- No `vim.schedule` inside `on_stdout`/`on_exit` (breaks headless tests)
- `string.find` returns nil on no-match → test `assert.is_nil`, not `is_false`
- Passwords only in in-memory URL; log through `util.redact_url`
