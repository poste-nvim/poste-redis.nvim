# AI Agent Practices — module health, DRY, tests

Guardrails for AI agents (and humans) changing this codebase. They exist
because the codebase already outgrew its first shape once: `buffer.lua`
(919 lines) and `browser/async.lua` (843 lines) each accreted several
responsibilities and had to be split retroactively. Follow these so the next
cleanup isn't yours.

## 1. One module, one responsibility

A module's header comment states its single job. If you can't say it in one
sentence, or the sentence needs two "and"s, the module is doing too much.

Soft size limits (heuristics, not gates):

| Size | Verdict |
|------|---------|
| < ~300 lines | healthy |
| 300–600 | fine if genuinely one concern |
| > ~600 lines **and** more than one concern | split before adding more |

Line count alone is never the trigger — `docs.lua` is 1100+ lines of pure
command-doc data plus one `lookup()` and needs no split. Mixed concerns are
the trigger: rendering + search + pagination + yank in one file was.

Split along seams that already exist in this repo instead of inventing new
shapes:

- **Facade + submodules** (`buffer.lua` + `buffer/*`): the old path stays the
  public API and keeps the thin delegations; internals move to
  `buffer/state|view|search|pager|preview|yank`. External callers and specs
  don't change.
- **Shared mutable state goes to the bottom** (`buffer/state.lua`): when
  submodules all touch the same state (buffer handles, tab list, cursor),
  move it to its own module everyone requires. Keep the dependency graph
  one-way — everything → state, features → view, facade → all. No require
  cycles, no setter-injection hacks.
- **Engine vs infrastructure** (`browser/scan.lua` vs `browser/async.lua`):
  pure loops/builders move out; the infrastructure they depend on (render
  hooks, uv-timer flush, view-mode flags) stays put and is exported
  explicitly (`M.schedule_render`, `M.render_now`, …).
- **Data is not code**: pure-data tables (command docs, completion COMMANDS)
  don't get split for size.

When a facade ends up bigger than planned, resist extracting keymap/registration
wiring into its own module if that wiring references half the facade's API —
a harmless-looking extraction that forces circular requires is worse than
~70 extra lines.

## 2. DRY — within this repo only

The red line inverts at the repo boundary: NO `require("poste-db.*")` /
`require("poste-http.*")`. Cross-repo "reuse" is a copied pattern, a vendored
file (`toml.lua`), or a shared `poste.*` module — by design. Never
de-duplicate by coupling this satellite to another one.

Inside poste-redis, two full copies of the same logic is one bug waiting to
be fixed in only one place:

- Before writing a helper, check `util.lua`, `format.lua`, and the feature
  module's exports — most primitives already exist (`util.redact_url`,
  `util.truncate_display`, `format.status_summary`, `result/grid.compute_matches`).
- If two functions differ only in constants or a predicate, parameterize
  instead of copy-pasting. Where parallel implementations are deliberate
  (the SCAN paging loops in `browser/scan.lua` and `async.search` share one
  pacing shape), a fix to one must be checked against the other.
- Shared mutable flags/counters belong in one owning module; reading a
  neighbor's local via a third module is a smell.

## 3. Tests move with behavior

- Every module has (or gets, in the same commit) a spec under `tests/redis/`
  named after it. New submodule → assertions live in the feature's existing
  spec unless the submodule has its own surface worth splitting out.
- `tests/run.sh` must be green and `luacheck lua tests` must not gain new
  warnings before every commit. Refactors keep the public API and spec
  assertions untouched; API changes update specs in the same commit.
  While iterating, `tests/run_one.sh tests/redis/<spec>.lua` runs a single
  file through the same scaffold (seconds, not the suite's minutes) — but a
  file run this way shares one nvim process, so it also exposes specs that
  leak state (cwd, `package.loaded`) into the ones after them.
- Expose internals for tests via the `M._test` table (see `parser`, `format`,
  `scan`, `value`, …) rather than skipping the test or widening the public API.
- Every new branch gets an assertion, not just the happy path: error paths,
  clamping, epoch/stale guards, wrap-around. Live-IO tests gate on
  `REDIS_TEST_URL` and `pending()` when it's absent.
- Config/default changes update the asserting spec in the same commit (a
  default and its test are one logical change).

## 4. Repo hygiene (small, non-negotiable)

- Naming: `poste-redis` = plugin/commands (`:PosteRedis*`), `poste_redis` =
  snake_case identifiers and the filetype. Never `poste_redis_*` as a command.
- All Redis I/O is async; callbacks are pcall'd + stale-guarded (epoch), and
  never `vim.schedule`d inside event callbacks (see Lua Pitfalls in AGENTS.md).
- Secrets: passwords only in the in-memory URL; redact with `util.redact_url`;
  never to history, files, or logs.
- Any file add/split/rename/retire updates `docs/dev/file-index.md` in the
  same commit — the index is the map agents navigate by.

## 5. Neovim API conventions (drawing, buffers, lifecycle)

### Separate data, layout, and drawing — yes, it's worth it

The payoff is testability and theme-ability, not architecture points:

- **Data stays raw**: `format.lua` keeps each cell's real value and exposes
  `to_display` (padded text) and `to_copy` (what the user yanks) separately —
  once display text is the only copy, yank fidelity is lost.
- **Layout is pure** (no `vim.*` calls): `result/grid.lua` computes display
  widths, rendered lines, and per-cell byte ranges (`col_starts`) as plain
  functions, so it runs headless in specs (and stays portable).
- **Drawing applies it**: `buffer/view.lua` owns the only
  `nvim_buf_set_lines` / extmark calls and maps pure byte ranges onto buffer
  lines.
- **Highlight definitions live in `highlights.lua`**; render sites reference
  the *names* (`"PosteRedisResultCell"`). Never hardcode colors or
  `vim.cmd("hi ...")` at a render site — users re-link groups to re-theme.

Don't force this on small features: a renderer emitting `{ line, hl_name }`
pairs inline (browser/tree.lua) is fine. The split pays when layout math gets
nontrivial (grids, floats, column maps), not for one-line highlights.

### Extmarks: one namespace per visual layer

`buffer/view.lua` layers value colors (priority 50), search matches (150),
and the cursor-cell highlight (200) in three namespaces, so each layer is
cleared and redrawn independently (`clear_namespace` per namespace) and
priority decides stacking. One shared namespace means clearing search wipes
the cursor highlight — the bug this pattern prevents.

### Scratch buffers and windows

- Panel/browser buffers follow one recipe: `nofile` + `bufhidden=hide` +
  `swapfile=false` + `modifiable=false` by default, a `poste://…` name, and
  a filetype for syntax.
- Toggle `modifiable` around every `nvim_buf_set_lines`, and pass an explicit
  end index (`nvim_buf_line_count`) — nvim 0.12's `set_lines(-1)` path can
  starve job stdout while results stream in (see view.lua / tree.lua notes).
- Set options scoped (`nvim_set_option_value(..., { buf = } / { win = })`),
  not globally.
- Check `nvim_win_is_valid` before use; pcall `nvim_win_close` /
  `nvim_buf_delete` on teardown; re-home the panel when the tabpage changed
  (`buffer.show_panel`'s panel_tabpage logic).
- Autocmds registered with `buffer = buf` die with the buffer; ones created
  manually (WinResized, WinScrolled) are tracked by id and deleted on close.

### uv callbacks are a fast context

uv timer callbacks run where nvim API calls are forbidden — wrap the body
with `vim.schedule_wrap` (async.lua `arm_flush`). This is the complement of
the AGENTS.md pitfall: no `vim.schedule` inside job event callbacks, but
always `schedule_wrap` inside uv callbacks.

### Keymaps

Bind feature keys only through `config.get_keymap(section, action, default)`
with the `if k then` guard — `false` disables a binding, everything else is
user-overridable. Hardcoded `vim.keymap.set` keys bypass the override layer
(the accepted exception: close keys on an ephemeral float the plugin owns).

### Testing UI code headless

Stub transport/IO by save-replace-restore (`session_conn.execute`,
`vim.ui.input`) inside the spec and restore in the same test — see the scan
tests in browser_spec. Assert on real buffer content via
`nvim_buf_get_lines`; plenary runs real windows in the isolated XDG, so no
mocking framework is needed.

## Pre-commit checklist

- [ ] The touched module still has one job — if the diff pushed a file past
      ~600 lines with a new concern, split first (patterns above)
- [ ] No logic duplicated that already exists in `util` / `format` / the
      owning module
- [ ] Dependency graph still acyclic; no new `require` of a DB/HTTP satellite
- [ ] Render sites reference highlight *names* only — no inline colors,
      no `vim.cmd("hi …")`; new visual layer → new extmark namespace
- [ ] `luacheck lua tests` — no new warnings
- [ ] `tests/run.sh` green
- [ ] `docs/dev/file-index.md` updated if files moved/appeared/disappeared
