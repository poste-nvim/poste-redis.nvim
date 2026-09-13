# poste-redis.nvim

Independent Redis plugin for Poste — self-contained since the poste.nvim
family dissolution: the former shared infra (state-lite, cli, util, select,
indicators, binary installer) is vendored under `lua/poste-redis/` (vendor
source poste.nvim@5b3759e). The family's shared `poste` binary — and its
`poste redis-exec` / `redis-session` subcommands (M1 transport) — is the only
cross-repo contract (schema: `../poste.nvim/docs/schema.md`).

## Key Facts

- All Lua lives under `lua/poste-redis/` — no runtime dependency on
  poste.nvim or any sibling
- Red line: NO `require("poste-db.*")` / `require("poste-http.*")` /
  `require("poste.*")` — every "reuse" is a copied pattern or vendored
- `poste-redis` / `poste_redis` = the plugin; `poste_redis` = ONLY the filetype
  (mirrors poste-db's naming convention)
- `plugin/poste-redis.lua` calls `require("poste-redis.init").setup()`
- `ftdetect/poste_redis.vim` sets the `poste_redis` filetype for `*.redis`
- M1 is exec-file only (D4): Lua parses `.redis` (D1), the Rust binary never
  sees file text
- `.opencode/skills/redis/SKILL.md` for agent context
- Test harness: `tests/run.sh` (isolated XDG, plenary); live redis e2e gated on
  `REDIS_TEST_URL` (CI runs a redis:7 service on 127.0.0.1:16479)

## File Index

See `docs/dev/file-index.md`.

## Naming

`poste-redis` = plugin/command namespace (`:PosteRedis*`).
`poste_redis` = snake_case identifiers AND the filetype.
Never write `poste_redis_*` as a command name; commands are `:PosteRedis*`.

## Design Principles

- Zero coupling to DB/HTTP satellites — no `require("poste-db...")` /
  `require("poste.http.*")`; AI is M2+ and only `pcall(require, "poste-ai")`
- Lua is the only parser (EXECUTION-PLAN D1); Rust receives token arrays
- Everything Redis I/O is async via jobstart; callbacks pcall'd + stale-guarded
- Secrets: passwords live only in the in-memory redis URL; logs redact
  (`util.redact_url`); never write passwords to history/files

## Module Health (short rules — details in `docs/dev/agent-practices.md`)

- One module, one job. A file past ~600 lines AND a second concern gets split
  first; reuse the established shapes (facade + `dir/` submodules, shared
  `state.lua` at the bottom, engine vs infra — see the practices doc)
- DRY within this repo only: check `util.lua` / `format.lua` before writing a
  helper; satellites stay decoupled (copy/vendor, never `require`)
- Tests are part of the change: `tests/run.sh` + no new luacheck warnings
  before every commit; new modules get a spec; internals exposed via `M._test`
- Drawing is layered: pure layout (no `vim.*`) → vim-API application →
  highlight *names* only at render sites (definitions live in
  `highlights.lua`); one extmark namespace per visual layer
- File add/split/rename updates `docs/dev/file-index.md` in the same commit

## Lua Pitfalls

### `guarded(seq, cb, ...)()` — not `guarded(...)(...)`

`guarded` returns a zero-arg closure; call it with a trailing `()`:
`guarded(my_seq, cb, arg1, arg2)()`. The pattern `guarded(...)(...)` is NOT
valid Lua (ambiguous "function call x new statement").

### No `vim.schedule` inside event callbacks

`on_stdout`/`on_exit` already run on the main loop. Do not wrap them in
`vim.schedule` — a schedule added mid-`vim.wait` is not pumped in headless
plenary runs, so test callbacks never fire. Call user callbacks directly.

### `assert.is_nil` vs `assert.is_false`

`string.find` returns `nil` (not `false`) on no-match. Test with
`assert.is_nil(r:find("x"))`, not `assert.is_false`.

### Local function forward declaration

A `local function B() end` is only visible after its definition. If an earlier
function A calls B, forward-declare `local B` first (same rule as poste-db).

## References

| Want | Go to |
|------|-------|
| Vendored shared infra (state, cli, select, indicators, installer) | `lua/poste-redis/` — vendor source poste.nvim@5b3759e `lua/poste/` |
| Binary NDJSON schema contract | `../poste.nvim/docs/schema.md` |
| Rust `redis-exec` / `redis_executor` | `../poste.nvim/crates/poste-cli/src/redis_exec.rs`, `crates/poste-exec/src/redis_executor.rs` |
| Requirements / execution plan | `requirements.md` / `EXECUTION-PLAN.md` |
