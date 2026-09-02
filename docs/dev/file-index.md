# poste-redis.nvim — File Index

M1 file execution loop is complete. M2 is implemented: `redis-session`
long-lived transport is in (Rust subcommand + `session_conn.lua`), browser /
value viewer are in, and tree-sitter highlighting is implemented with regex
fallback — see `requirements.md`.

## Entry points

| File | Role |
|------|------|
| `plugin/poste-redis.lua` | Loads `poste-redis.init.setup()` |
| `ftdetect/poste_redis.vim` | `*.redis` → `poste_redis` filetype |
| `ftplugin/poste_redis.vim` | commentstring `# %s`, indent settings |
| `syntax/poste_redis.vim` | M1 regex syntax fallback (command / string / comment / USE / continuation / inline tails) |
| `lua/poste-redis/init.lua` | `M.setup(opts)`: config → highlights → autocmds → commands → existing buffers |

## Core Lua (`lua/poste-redis/`)

### Execution pipeline

| File | Role |
|------|------|
| `parser.lua` | **The only parser (D1)**: `extract_entries` (continuations joined, quote-aware comments, `USE`), `cursor_entry`, `visual_entries`, `file_entries`, `entry_args` |
| `exec_run.lua` | `run_async` (stdin JSON → `poste redis-exec` → NDJSON events), `run_file_async` (USE grouping, sequential batches), `run_sync`, `run_selection_async`, stale-guard + busy bookkeeping |
| `session_conn.lua` | **M2**: persistent session pool (`poste redis-session`) — `get`/`execute`/`stop`/`stop_all`/`cleanup_buf`/`list`; requests `{seq, command}`, responses are redis-exec-style result events; SELECT state survives across requests; `opts.db` auto-SELECTs on db change |
| `runner.lua` | `<CR>` / `:PosteRedisRunFile` entry: connects exec_run → buffer → history, spinner indicators |
| `format.lua` | `format_result` → `{kind}` — "text" for nil/int/string/binary/stream/unknown/error; "table" grid for list/set/hash/zset (`columns` + raw `rows`, `to_display`/`to_copy`); `format_error`, `preview_json`, `status_summary` |
| `buffer.lua` | Result panel: `poste://redis_result`, per-command tabs, `<Tab>`/`<S-Tab>`. Text tabs keep the compact block; table tabs render the grid with floating header + cell/page navigation + search + yank |
| `result/grid.lua` | **Pure table-grid renderer**: `build_layout` (display widths + right-align), `render_page` (borderless `│` rows + col byte maps + pagination), `compute_matches` / `cell_match_range` (search). No vim ops — reusable in poste.nvim later |
| `result/header.lua` | Floating fixed header for grid tabs (1-line float over the panel following horizontal scroll, per-char viewport slicing) |
| `history.lua` | In-memory execution history + float list (j/k/CR/q) |

### Key browser (`browser/`)

| File | Role |
|------|------|
| `tree.lua` | Node model (connection → db → group → key), flatten + highlights, `get_node_at_line` |
| `async.lua` | SCAN cursor batching (`config.scan_count`), MATCH filter, `:`-prefix grouping (tree view) / flat view, epoch stale guard; `load_connections`, `fetch_dbs` (DBSIZE probe) |
| `value.lua` | TYPE-first paginated value viewer: HSCAN/SSCAN/ZSCAN pages, LRANGE windows, XRANGE, string GET (truncated + `F` full load); page tabs + loaded/total footer |
| `actions.lua` | **P1-4 write actions**: delete_key / delete_prefix (SCAN estimate + double confirm) / set_ttl (EXPIRE/PERSIST) / rename_key (EXISTS conflict check) — all via session, unified confirm gate |
| `init.lua` | `poste://redis_browser` right-hand split, keymaps, `:PosteRedisBrowser` / `:PosteRedisBrowserView` |

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
| `commands.lua` | `:PosteRedisConnection` / `:PosteRedisRunFile` / `:PosteRedisHistory` / `:PosteRedisInfo` / `:PosteRedisBrowser` / `:PosteRedisBrowserView` |
| `health.lua` | `:checkhealth poste-redis` |
| `highlights.lua` | `PosteRedis*` groups (source + result panel + history) |
| `treesitter.lua` | parser availability probe, enable tree-sitter highlighting, keep regex fallback |
| `install.lua` | compile tree-sitter-poste-redis/src/parser.c into `stdpath("data")/site/parser` (needs cc; silent no-op otherwise) |
| `util.lua` | `redact_url`, `display_width`, `truncate_display`, `pad_*`, `escape_for_line`, `format_latency` |

### Completion (`completion/`, P2-4)

| File | Role |
|------|------|
| `ctx.lua` | context detection (`command` / `USE` connection / `key` arg position) + item helpers (`fuzzy_match`, `make_items`, `filter`) |
| `data.lua` | `COMMANDS` table (~190), `ensure_conn_names` (connections.toml), `ensure_key_candidates` (SCAN MATCH prefix* via session_conn, cached per url+prefix) |
| `init.lua` | orchestrator `get_items` dispatch + blink.cmp source (`M.new`/`get_completions`) + nvim-cmp `M.source` |
| `adapter.lua` | blink.cmp adapter wrapper (`register_source`, `register_filetype`, `show`) |
| `register.lua` | register the `poste_redis` blink source for the filetype |

## Tests (`tests/`)

| File | Covers |
|------|--------|
| `redis/parser_spec.lua` | §4.2 matrix: continuations, quote-aware `#`, USE, CRLF, unquote, dangerous |
| `redis/connections_spec.lua` | §5: url/field forms, `{{var}}` + `.env`/OS, errors, list, use_connection |
| `redis/config_spec.lua` | defaults, merge, keymap resolution |
| `redis/toml_spec.lua` | vendored parser (sections, escapes, errors) |
| `redis/format_spec.lua` | value rendering incl. binary / truncated / CJK / grid model for list/set/hash/zset |
| `redis/result_grid_spec.lua` | grid: layout widths, render_page + pagination, panel cell navigation, page flip, search, yank cell/column, preview, header slicing |
| `redis/exec_run_spec.lua` | transport contract (stubbed `poste.cli`), stale-guard, USE grouping |
| `redis/session_conn_spec.lua` | M2 session pool (stubbed jobstart): start args, reuse, seq pairing, error routing, exit drops session, cleanup_buf, db auto-SELECT, chunk-split stdout |
| `redis/browser_spec.lua` | browser: tree flatten/markers, `:`-grouping, flat/tree toggle, value page commands + live-redis e2e (SCAN groups, string/hash value render, TTL/DEL/RENAME) |
| `redis/browser_actions_spec.lua` | P1-4 write actions (stubbed session+confirm+input): delete confirm/cancel, prefix estimate, TTL, rename conflict |
| `redis/buffer_spec.lua` | panel tabs, preview, yank, close, grid tab render |
| `redis/history_spec.lua` | push/list/cap, float, activate→panel |
| `redis/completion_spec.lua` | P2-4: ctx detection, command table, conn names, SCAN key-prefix fetch+cache (stubbed session), orchestrator dispatch |
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
| M2 exit: 100k-key acceptance script (P1-1 first-screen < 300ms) | done |
| completion (P2-4): command table + USE connection names + key-prefix SCAN hints | done |
| write ops / command palette / export (P2) | not started |
