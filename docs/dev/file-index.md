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
| `parser.lua` | **The only parser (D1)**: `extract_entries` (continuations joined, boundary-anchored quote-aware comments — a `#`/`--` comment starter must sit at a word boundary, mid-word it is key content, `USE`), `cursor_entry`, `visual_entries`, `file_entries`, `entry_args` `buffer_entries` takes { max_line } for bounded hot-path parses. The command head is decoded (quotes stripped, uppercased) for `entry.command`/`entry_args`/`key_arg`, so `"FLUSHALL"` cannot slip past the blacklist; `raw` keeps the line as written |
| `exec_run.lua` | `run_async` (stdin JSON → `poste redis-exec` → NDJSON events), `run_file_async` (USE grouping, sequential batches, SELECT-aware db stamped as `ev.db`), `run_sync`, `run_selection_async`, stale-guard + busy bookkeeping |
| `session_conn.lua` | **M2**: persistent session pool (`poste redis-session`) — `get`/`execute`/`stop`/`stop_all`/`cleanup_buf`/`release`/`list`; `opts.owner` tags a logical owner, `release(owner)` stops solely-held sessions; requests `{seq, command}`, responses are redis-exec-style result events; SELECT state survives across requests; `opts.db` auto-SELECTs on db change |
| `runner.lua` | `<CR>` / `:PosteRedisRunFile` entry: connects exec_run → buffer → history, spinner indicators, silently preselects the file's declared db for line/selection runs (SELECT result swallowed), and gates a batch that contains a blacklisted command behind one confirm (`confirm_commands`) |
| `format.lua` | `format_result` → `{kind}` — "text" for nil/int/string/binary/stream/unknown/error; "table" grid for list/set/hash/zset (`columns` + raw `rows`, `to_display`/`to_copy`); `format_error`, `preview_json`, `status_summary` |
| `buffer.lua` | Result panel facade: `poste://redis_result`, per-command tabs, `<Tab>`/`<S-Tab>`, panel keymaps, `r` refresh, TTL probe + countdown. Stamps each tab's origin context (connection / db / key) so grid editing writes where the command ran. Delegates to `buffer/*` |
| `buffer/state.lua` | Shared mutable panel state (buf/win/tabs/active/last_value, PAGE_SIZE) — depended on by all `buffer/*` modules, no cycles |
| `buffer/view.lua` | All drawing: grid page renderer, cell highlight + value colors + search extmarks, floating header, winbar |
| `buffer/search.lua` | In-grid search state (search_text/matches/idx on the tab) + match navigation (page-flipping jumps) |
| `buffer/pager.lua` | Grid page flipping (wrapping) for table tabs |
| `buffer/preview.lua` | `K` float preview: raw JSON (text tabs) / current cell (table tabs) |
| `buffer/yank.lua` | Yank whole tab / current cell / current column |
| `buffer/export.lua` | Grid export on `E`: RFC 4180 CSV / TSV / one-object-per-line JSON, whole grid (all pages), index column never exported, truncation surfaced in the notify |
| `buffer/sort.lua` | Column sort on `s` (none → desc → asc → none): numeric-aware stable re-order of grid rows, cursor follows the focused record, sort icon byte-range in the rendered header (link @number) |
| `result/grid.lua` | **Pure table-grid renderer**: `build_layout` (display widths + right-align), `render_page` (borderless `│` rows + col byte maps + pagination), `compute_matches` / `cell_match_range` (search). No vim ops — reusable in poste.nvim later |
| `result/header.lua` | Floating fixed header for grid tabs (1-line float over the panel following horizontal scroll, per-char viewport slicing) |
| `ui.lua` | Shared centered modal float (scratch buffer + rounded border + q/Esc close) — used by the result preview and source help |
| `history.lua` | In-memory command history: .redis runs + dataset/grid_edit writes + browser mutations (batch deletes aggregate to one `DEL prefix:*`, `yank` carries an executable redis-cli pipeline). Sidebar float beside the result panel (the panel narrows while the sidebar is open so the float never covers data; width restored on close): j/k previews the entry live — entries with a raw value re-render as a real grid tab (floating header, cell nav, `K`); entries without one fall back to the text snapshot, `<Tab>` jumps focus into the panel (live cursor/K/yank there), `<CR>` commits + closes, `y` yanks, `q`/`<Esc>` close (an open toggle re-focuses instead of closing); command left + highlighted, exec time right-aligned gray |

### Key browser (`browser/`)

| File | Role |
|------|------|
| `tree.lua` | Node model (connection → db → group → key), flatten + highlights, gray child counts on group rows (eol virt text), `get_node_at_line` |
| `async.lua` | Browser async infrastructure: render/append hooks + uv-timer flush (buffer work never runs in job callbacks), view mode (flat/flatten/nested), bounded TYPE fetch, fuzzy substring search (`MATCH *query*`, glob-escaped; results bucketed via the `results_build` hook → scan's eager builders), `load_connections`, `fetch_dbs` (DBSIZE probe) |
| `scan.lua` | Cursor-driven SCAN loops + tree builders: `scan_keys` (lazy db group headers, `header_scan_count`), `scan_group` (MATCH prefix, nested subfolders, `scan_count`), `build_children` / `build_nested_children` (view rebuild), `build_search_results` (search matches bucketed under their real folders, expanded), lazy-header stamps — nested view pre-folds each header to its single-spine branch point (`spine_fold`/`respine_headers`) with a direct-children count, flatten view keeps keys-under-prefix totals — epoch stale guard. Depends on async's pacing — never the reverse |
| `value.lua` | TYPE-first paginated value viewer: HSCAN/SSCAN/ZSCAN pages, LRANGE windows, XRANGE, string GET (truncated + `F` full load); page tabs + loaded/total footer |
| `actions.lua` | **P1-4 write actions**: delete_key / delete_prefix (SCAN estimate + double confirm) / set_ttl (EXPIRE/PERSIST) / rename_key (EXISTS conflict check) — all via session, unified confirm gate; every mutation lands in the command history (batches as one aggregated entry) |
| `header_bar.lua` | Pinned header chrome: mirrors the browser buffer's header lines 1-2 (filter bar + separator) into a borderless float anchored to the window's top rows (result/header.lua pattern), so the bar stays visible while the tree scrolls; hidden while the bar is edited, dies with the window (WinClosed) |
| `init.lua` | Browser facade: `poste://redis_browser` right-hand split (gutter-free), keymaps, render pipeline (render_tree + async hooks), `open`/`close`/`toggle_view`/`search_clear`/`reveal` public API, `g?` help. Delegates to `browser/*` |
| `state.lua` | Shared mutable browser state (buf/win/line_to_node/scope/search/picker/multi-select/reveal fields) + `window()` re-resolution, `reset_scope`, `select_db` — depended on by all `browser/*` modules, no cycles |
| `searchbar.lua` | Search-bar editing (<leader>/ → insert on line 1, <CR> search, Esc cancel) + the cursor clamp that keeps the caret off the pinned header rows |
| `picker.lua` | First-open connections list: sorted in-window rows (redacted URLs), <CR> connects (global context follows), db 0 |
| `reveal.lua` | Reveal-a-key walker: re-scopes (connection/db), expands the folder path across renders, parks the cursor on the key's row |

### Configuration & connections

| File | Role |
|------|------|
| `config.lua` | `M.defaults` (preview_max_bytes, scan_count, keymaps sections), `merge`, `get_keymap`, `format_key_string` |
| `state.lua` | `M.context = { connection, db }`, `M.last_response`, `M.TITLE`; + state-lite merged from poste.nvim@5b3759e (`config` singleton, `find_poste_binary`, `apply_highlight_overrides`, `log`) |
| `constants.lua` | URL prefix detection, panel/float dims, `MAX_PREVIEW_BYTES`, dangerous-command blacklist; spinner/indicator constants merged from poste.nvim@5b3759e |
| `cli.lua` | VENDORED from poste.nvim@5b3759e `lua/poste/cli.lua` — poste binary wrapper (`run`/`run_json`/`run_async`) |
| `select.lua` | VENDORED from poste.nvim@5b3759e `lua/poste/select.lua` — snacks → float → `vim.ui.select` picker |
| `indicators.lua` | VENDORED from poste.nvim@5b3759e `lua/poste/indicators.lua` — sign-column spinner / ✓ / ✘ + eol latency virt-text |
| `install_binary.lua` | VENDORED from poste.nvim@5b3759e `lua/poste/install.lua`, trimmed (no git-tag version sync) — ensures the family poste binary (named `install_binary` because `install.lua` is the parser compiler) |
| `connections.lua` | `find_connections_toml` (walk-up + mtime cache), `resolve_redis_url` (url form / field form / `{{var}}`), `use_connection`, `select_connection` |
| `toml.lua` | **Vendored** from poste-db (`lua/poste-db/toml.lua`) — see file header for sync instructions |
| `context.lua` | **Window-scoped context resolution** — what connection+db a window is about: result panel (active tab's stamped meta) > browser (current scope) > `.redis` file (effective USE/SELECT at the cursor, mirrors what `<CR>` resolves) > global context. `entries_context` pure per-file walk, `display` ("local db3" / credential-free host) |
| `statusline.lua` | Statusline context segment — colored by connections.toml `color`/`link`/`bg` (`get_ctx_color`), auto-wired into mini.statusline / lualine (`setup({ statusline = false })` opts out). Since the family dissolution the mini wiring is scope-guarded: renders only on windows redis owns (panel/browser/.redis file), falls through to the captured original elsewhere — the global session fallback is no longer rendered |
| `winbar.lua` | **Source-buffer context winbar** — `.redis` buffer top bar showing the cursor's effective context, repainted on CursorMoved/WinEnter; gated behind `config.source_winbar` |

### UI wiring

| File | Role |
|------|------|
| `buffer_setup.lua` | Source-buffer keymaps (run n+v, `gd` reveal into the browser tree, history, K docs, help float) |
| `docs.lua` | Redis command doc data (~190 commands: category, syntax, desc, examples) + `lookup` — feeds the `K` hover |
| `doc.lua` | `K` hover provider: vendored `open_doc_preview` (markdown float, track_key re-focus = second `K` focuses the popup) + `show_command_doc`/`build_lines` |
| `autocmds.lua` | `FileType poste_redis` wiring + `setup_existing_buffers` |
| `commands.lua` | `:PosteRedisConnection` / `:PosteRedisRunFile` / `:PosteRedisHistory` / `:PosteRedisInfo` / `:PosteRedisBrowser` / `:PosteRedisBrowserView` / `:PosteRedisReveal [key]` |
| `health.lua` | `:checkhealth poste-redis` |
| `highlights.lua` | `PosteRedis*` groups (source + result panel + history) |
| `treesitter.lua` | parser availability probe, enable tree-sitter highlighting, keep regex fallback |
| `install.lua` | compile tree-sitter-poste-redis/src/parser.c into `stdpath("data")/site/parser` (needs cc; silent no-op otherwise) |
| `util.lua` | `redact_url`, `glob_escape`, `render_command`, `display_width`, `truncate_display`, `pad_*`, `escape_for_line`, `format_latency`; + `clean_nil`/`find_file_upwards`/`ensure_job_data` merged from poste.nvim@5b3759e |

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
| `redis/parser_spec.lua` | §4.2 matrix: continuations, quote-aware `#`, USE, CRLF, unquote, dangerous (incl. a quoted command head) |
| `redis/connections_spec.lua` | §5: url/field forms, `{{var}}` + `.env`/OS, errors (port/db validation incl. the 16-bit port bound, cached parse failure), list, use_connection |
| `redis/config_spec.lua` | defaults, merge, keymap resolution |
| `redis/toml_spec.lua` | vendored parser (sections, escapes, errors) |
| `redis/format_spec.lua` | value rendering incl. binary / truncated / CJK / grid model for list/set/hash/zset |
| `redis/result_grid_spec.lua` | grid: layout widths, render_page + pagination, panel cell navigation, page flip, search, yank cell/column, preview, header slicing |
| `redis/exec_run_spec.lua` | transport contract (stubbed `poste-redis.cli`), stale-guard, USE grouping |
| `redis/runner_spec.lua` | `<CR>`/run-file orchestration: per-line indicators on the source buffer, USE/`<CR>` picker, visual range capture, `cancel_current`, and the destructive-command confirm gate (ask / yes / no / quoted name / `confirm_commands = false`) |
| `redis/session_conn_spec.lua` | M2 session pool (stubbed jobstart): start args, reuse, seq pairing, error routing, exit drops session, cleanup_buf, db auto-SELECT, chunk-split stdout |
| `redis/browser_spec.lua` | browser: tree flatten/markers, `:`-grouping, flat/flatten/nested view modes, value page commands + live-redis e2e (SCAN groups, string/hash value render, TTL/DEL/RENAME) |
| `redis/browser_actions_spec.lua` | P1-4 write actions (stubbed session+confirm+input): delete confirm/cancel, prefix estimate, TTL, rename conflict |
| `redis/buffer_spec.lua` | panel tabs, preview, yank, close, grid tab render |
| `redis/yank_spec.lua` | register targets (" and +), page arithmetic, text-tab fallback |
| `redis/pager_spec.lua` | page flip/wrap on table tabs (first/last/next/prev), single-page and text-tab no-ops, re-render sequencing |
| `redis/search_spec.lua` | in-grid search: case-insensitive match compute (real grid), jump page arithmetic, next/prev wrap, empty-result notice, nil-match hardening |
| `redis/export_spec.lua` | csv quoting, tsv cleaning, json shape, export() guards |
| `redis/history_spec.lua` | push/list/cap, float, activate→panel |
| `redis/completion_spec.lua` | P2-4: ctx detection, command table, conn names, SCAN key-prefix fetch+cache (stubbed session), orchestrator dispatch |
| `redis/value_spec.lua` | value viewer: per-type page commands, progressive pagination (done from the updated cursor, `<Tab>` fetches the next page, exhausted cursor stops) |
| `redis/ai_spec.lua` | AI context: confirm gate (dangerous ask + refusal), execute_redis error reporting + idempotent cleanup |
| `redis/context_spec.lua` | window-scoped context: `entries_context` USE/SELECT walk, `display` formatting (host redaction), `resolve` priority chain (panel/browser/.redis/global) |
| `redis/docs_spec.lua` | docs data parity with COMMANDS + entry shape, `build_lines` markdown, `resolve_command`, float track_key re-focus, show_doc keymap |
| `redis/e2e_spec.lua` | live redis (gated on `REDIS_TEST_URL`) |
| `scaffold_spec.lua` | harness smoke |

`tests/run.sh` runs the directory; `tests/run_one.sh tests/redis/x_spec.lua`
runs one file through the same scaffold.

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
| write ops / command palette (P2) | not started |
| result-grid export (P2): `E` writes the active grid to csv/tsv/json | done |
