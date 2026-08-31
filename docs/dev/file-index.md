# poste-redis.nvim — File Index

M1 file execution loop is complete. M2 started: `redis-session` long-lived
transport is in (Rust subcommand + `session_conn.lua`); browser / value
viewer / tree-sitter are not started yet — see `requirements.md`.

## Entry points

| File | Role |
|------|------|
| `plugin/poste-redis.lua` | Loads `poste-redis.init.setup()` |
| `ftdetect/poste_redis.vim` | `*.redis` → `poste_redis` filetype |
| `ftplugin/poste_redis.vim` | commentstring `# %s`, indent settings |
| `syntax/poste_redis.vim` | M1 regex syntax (command / string / comment / USE / continuation) |
| `lua/poste-redis/init.lua` | `M.setup(opts)`: config → highlights → autocmds → commands → existing buffers |

## Core Lua (`lua/poste-redis/`)

### Execution pipeline

| File | Role |
|------|------|
| `parser.lua` | **The only parser (D1)**: `extract_entries` (continuations joined, quote-aware comments, `USE`), `cursor_entry`, `visual_entries`, `file_entries`, `entry_args` |
| `exec_run.lua` | `run_async` (stdin JSON → `poste redis-exec` → NDJSON events), `run_file_async` (USE grouping, sequential batches), `run_sync`, `run_selection_async`, stale-guard + busy bookkeeping |
| `session_conn.lua` | **M2**: persistent session pool (`poste redis-session`) — `get`/`execute`/`stop`/`stop_all`/`cleanup_buf`/`list`; requests `{seq, command}`, responses are redis-exec-style result events; SELECT state survives across requests |
| `runner.lua` | `<CR>` / `:PosteRedisRunFile` entry: connects exec_run → buffer → history, spinner indicators |
| `format.lua` | `format_result` (nil/int/string/binary/list/hash/zset/stream/unknown), `format_error`, `preview_json`, `status_summary` |
| `buffer.lua` | M1 result panel (D2): `poste://redis_result`, per-command tabs, `<Tab>`/`<S-Tab>`, `K` raw JSON float, `q` close, `yy` yank |
| `history.lua` | In-memory execution history + float list (j/k/CR/q) |

### Configuration & connections

| File | Role |
|------|------|
| `config.lua` | `M.defaults` (preview_max_bytes, scan_count, keymaps sections), `merge`, `get_keymap`, `format_key_string` |
| `state.lua` | `M.context = { connection, db }`, `M.last_response`, `M.TITLE` |
| `constants.lua` | URL prefix detection, panel/float dims, `MAX_PREVIEW_BYTES`, dangerous-command blacklist |
| `connections.lua` | `find_connections_toml` (walk-up + mtime cache), `resolve_redis_url` (url form / field form / `{{var}}`), `use_connection`, `select_connection` |
| `toml.lua` | **Vendored** from poste-db (`lua/poste-db/toml.lua`) — see file header for sync instructions |

### UI wiring

| File | Role |
|------|------|
| `buffer_setup.lua` | Source-buffer keymaps (run n+v, history, help float) |
| `autocmds.lua` | `FileType poste_redis` wiring + `setup_existing_buffers` |
| `commands.lua` | `:PosteRedisConnection` / `:PosteRedisRunFile` / `:PosteRedisHistory` / `:PosteRedisInfo` |
| `health.lua` | `:checkhealth poste-redis` |
| `highlights.lua` | `PosteRedis*` groups (source + result panel + history) |
| `util.lua` | `redact_url`, `display_width`, `truncate_display`, `pad_*`, `escape_for_line`, `format_latency` |

## Tests (`tests/`)

| File | Covers |
|------|--------|
| `redis/parser_spec.lua` | §4.2 matrix: continuations, quote-aware `#`, USE, CRLF, unquote, dangerous |
| `redis/connections_spec.lua` | §5: url/field forms, `{{var}}` + `.env`/OS, errors, list, use_connection |
| `redis/config_spec.lua` | defaults, merge, keymap resolution |
| `redis/toml_spec.lua` | vendored parser (sections, escapes, errors) |
| `redis/format_spec.lua` | value rendering incl. binary / truncated / CJK |
| `redis/exec_run_spec.lua` | transport contract (stubbed `poste.cli`), stale-guard, USE grouping |
| `redis/session_conn_spec.lua` | M2 session pool (stubbed jobstart): start args, reuse, seq pairing, error routing, exit drops session, cleanup_buf, chunk-split stdout |
| `redis/buffer_spec.lua` | panel tabs, preview, yank, close |
| `redis/history_spec.lua` | push/list/cap, float, activate→panel |
| `redis/e2e_spec.lua` | live redis (gated on `REDIS_TEST_URL`) |
| `scaffold_spec.lua` | harness smoke |

## Rust (lives in `../poste.nvim`)

| File | Role |
|------|------|
| `crates/poste-exec/src/redis_executor.rs` | `execute_commands_with`, `execute_command_on` (shared one-shot/session path), `redis_value_to_json` (len/truncated), `parse_shell_args` |
| `crates/poste-cli/src/redis_exec.rs` | `poste redis-exec`: stdin `{connection, commands}` → NDJSON events |
| `crates/poste-cli/src/redis_session.rs` | `poste redis-session`: stdin-lines loop `{seq, command}` → result events; one connection, SELECT state persists |

## Next TODO

| Area | Status |
|------|--------|
| `browser/` key browser | not started |
| value viewer / large-key navigation | not started |
| tree-sitter grammar | not started |
| write ops / command palette / completion / export | not started |
