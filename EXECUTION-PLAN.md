# poste-redis.nvim — M1 执行规格（EXECUTION PLAN）

> 本文档是 **AI agent 可独立执行的工作单**，只覆盖 M1（文件执行闭环）。
> 阅读顺序：`requirements.md`（为什么）→ 本文档（怎么干）→ 各仓库 AGENTS.md（仓库规矩）。
> 与 requirements.md 冲突时以本文档为准（更具体、更新）。

---

## 0. 工作方式（agent 必读）

**开工前按序阅读**（约 30 分钟）：

1. `requirements.md` — 本插件的目标、范式、优先级
2. 本文档 — M1 的每一刀切在哪里
3. `../poste.nvim/AGENTS.md` — 家族共享 infra 的规矩（protocol-agnostic 红线）
4. `../poste-db.nvim/AGENTS.md` — 卫星插件惯例（naming 三段式、Lua pitfalls、harness 顺序）
5. `../poste-ai.nvim/AGENTS.md` — "Neovim Plugin Development Conventions" 一节（API 陷阱清单全部适用）

**开发纪律**：

- TDD：每个工作项先写 spec/cargo test 再写实现；`tests/run.sh` 与 `cargo test` 全绿才算完成一项
- 禁止跨卫星 require：Lua 里永远不出现 `require("poste-db...")` / `require("poste-http...")`
- 凭据纪律：密码只以 `{{var}}` 展开后的形式存在于内存 URL；日志一律走 redact
- 每完成一个工作项 git commit 一次，message 风格照 poste-db 仓库（`feat(scope): ...`）

**本地二进制开发循环**（Lua 联调）：

```bash
cd ../poste.nvim && cargo build --release   # 产出 ../poste.nvim/target/release/poste
# poste 的 find_poste_binary 会发现 plugin-relative target/release；
# 或在 poste-redis 的 minimal_init 里 vim.g.poste_binary = "../poste.nvim/target/release/poste"
```

---

## 1. 仓库脚手架清单（工作项 #1，一次做完）

本仓库当前只有 requirements.md / EXECUTION-PLAN.md。M1 第一项是照家族模板建齐：

| 文件 | 来源模板 | 要点 |
|------|----------|------|
| `.stylua.toml` / `.editorconfig` / `.luacheckrc` | poste-ai.nvim | 原样拷贝 |
| `.gitignore` | poste-ai.nvim | 忽略 .env*、nvim.log |
| `tests/run.sh` | poste-ai.nvim | 隔离 XDG；rtp 追加 `.`、`../poste.nvim`（**本插件是唯一依赖**） |
| `tests/minimal_init.lua` | 同上 | rtp 追加 + `vim.g.poste_binary` 兜底指向 `../poste.nvim/target/release/poste` |
| `tests/fixtures/` | — | `redis_connections.toml`、命令解析 fixture（见 §4.3） |
| `playground/docker-compose.yml` | poste-db 同款改造 | `redis:7-alpine`，端口 `16379:6379`，无密码 + 一个 `requirepass` 实例（二选一按 CI 简化） |
| `.github/workflows/ci.yml` | poste-db ci.yml | checkout poste.nvim 为 sibling；services 起 redis:7（127.0.0.1:16379）；跑 run.sh |
| `LICENSE`（MIT）/ `README.md` | — | README 安装段注明"依赖 poste.nvim（自动下载二进制）" |
| `AGENTS.md` | poste-ai.nvim 模板 | Key Facts / File Index / naming（poste-redis / poste_redis / filetype `poste_redis`）/ pitfalls；M1 收尾时写 |
| `plugin/poste-redis.lua` | poste-db plugin 文件 | pcall poste.state → `require("poste-redis.init").setup()` |
| `ftdetect/poste_redis.vim`、`ftplugin/poste_redis.vim`（commentstring `# %s`）、`syntax/poste_redis.vim` | poste-db 同名文件 | filetype `poste_redis` |

---

## 2. 关键决策（已裁决，不得自行更改）

| # | 决策 | 理由 |
|---|------|------|
| D1 | **Rust 不解析 `.redis` 文件**。Lua 是唯一解析器：行提取、续行拼接、引号扫描、`USE` 识别全在 Lua；Rust 只接收命令数组 | 避免 Lua/Rust 双份文件格式解析发散；`.redis` 语法演进只动一处；session/exec 两级传输天然共用 |
| D2 | **结果面板自建精简版**（单 buffer `poste://redis_result` + 每命令一个 tab，q 关闭、`<Tab>` 切换、`K` 原始 JSON 预览）。不移植 poste-db 的 dataset 全家桶（分页/编辑/筛选） | requirements §2.3 的"复用"指**照抄模式**，运行时严禁跨卫星 require；M1 面板 < 300 行即够，M3 再评估功能需求 |
| D3 | 事件流 JSON 键用 `"type"`（`progress/result/summary`），与 SQL exec-file 完全一致——Lua 侧事件循环可直接对齐 `exec_run.lua` 的 `for_each_event` | 家族一致性；per-命令错误是 `status:"error"` 的 result 事件（greedy 继续），不是独立 error 事件 |
| D4 | 传输 M1 只有 `redis-exec`（单次进程）。`redis-session` 是 M2 第一项，M1 所有验收在 exec 模式下达成 | session 模式是浏览器/SELECT 保持的前提，但文件闭环不需要它 |
| D5 | `toml.lua` 从 poste-db **vendor 拷贝**（文件头注明来源与同步说明），不共享模块 | 零耦合红线下唯一可行解；该文件纯函数、稳定 |
| D6 | Redis 命令名大小写不敏感；参数不解析语义（Rust 侧 `redis::cmd(name)` 透传） | 解析器保持"哑"，语义错误交给 Redis 返回 WRONGTYPE/ERR |

---

## 3. Rust 移植地图（工作项 #2、#3）

### 3.1 源 → 目标对照

| 源（poste-data-modification，只读参考仓库） | 目标（poste.nvim） | 动作 |
|---|---|---|
| `crates/poste-exec/Cargo.toml:26` `redis = { version = "0.27", features = ["tokio-comp"] }` | `crates/poste-exec/Cargo.toml` | 加依赖 |
| `crates/poste-exec/src/executor.rs:164-243` `execute_redis` | 新文件 `crates/poste-exec/src/redis_executor.rs` | **重写为纯函数形态**：`pub async fn execute_commands(connection_url: &str, commands: &[Vec<String>], max_payload: usize) -> Result<Vec<CommandOutcome>>`。去掉 `Request`/`Response` 外壳（那是旧 monolith 的形状），保留：`redis::Client::open` → `get_multiplexed_async_connection`、逐命令 `redis::cmd(name)` 透传、错误不停（greedy） |
| `executor.rs:348+` `redis_value_to_json` | 同上文件 | 原样移植 + 补 `truncated`/`len` 字段（§4.3）；其单测一并移植 |
| `executor.rs:506+` `parse_shell_args` | 同上文件 | 原样移植（引号/转义的 shell-args 解析，M1 唯一的参数语义处理） |

### 3.2 新子命令 `poste redis-exec`（M1 唯一 Rust 交付）

- 注册：`crates/poste-cli/src/main.rs` `enum Commands` 加 `RedisExec(RedisExecArgs)`（模仿 `ExecFile` 写法；新文件 `crates/poste-cli/src/redis_exec.rs`）
- 输入：**stdin 单行 JSON**（同 `poste context stmt` 的 stdin 模式，**不读文件**——D1）：

```json
{"connection": "redis://:pass@127.0.0.1:16379/0", "commands": [["GET","user:42"], ["SET","k","v","EX","60"]]}
```

- 输出：stdout 逐行 JSON，键与 SQL exec-file 对齐（exec_file.rs:131/369/474 的形状）：

```json
{"type":"progress","index":1,"total":2,"command":"GET user:42"}
{"type":"result","seq":1,"command":"GET user:42","status":"\"Alice\"","latency_ms":2,"value":{"type":"string","value":"Alice"}}
{"type":"result","seq":2,"command":"SET k v EX 60","status":"OK","latency_ms":1,"value":{"type":"string","value":"OK"}}
{"type":"summary","total":2,"failed":0,"elapsed_ms":4}
```

- 语义：连接失败 → stderr + exit 1（无事件）；单命令失败 → `status:"error"` + `error` 字段的 result 事件，继续下一条；exit 0
- 协议判定：`connection` 以 `redis://` / `rediss://` 开头，否则 bail（对齐 exec_file.rs:71-86 的判定写法）
- **测试**：cargo 单测（parse_shell_args、redis_value_to_json 各类型 + 新增 truncated）+ `#[ignore]` 集成测试（`REDIS_TEST_URL` 环境变量存在才跑，CI 里设）

### 3.3 M2 预告（本文档不展开）

`poste redis-session --connection <url>`：照 `session.rs` 的 stdin-lines 循环写 `session_redis`；请求 `{seq, command:[...]}`，响应 `{"type":"result","seq":..}`；推送事件 `{"type":"push","kind":"monitor"|"pubsub","payload":{...}}`；支持 `SELECT` 状态保持。

---

## 4. Lua M1 文件蓝图（工作项 #4–#9）

所有文件在 `lua/poste-redis/`。标注"参照"的是移植/对齐来源（**照抄模式，改命名，不 require**）。

| 文件 | 职责与关键函数 | 参照 |
|------|----------------|------|
| `config.lua` | `M.defaults`（browser 占位、`keymaps` 三 section、`preview_max_bytes = 65536`、`scan_count = 500`）、`M.config`、`M.merge(opts)`、`M.get_keymap(section, action, default)`、`M.format_key_string(key)` | poste-db config.lua |
| `state.lua` | `M.context = { connection, db }`（当前连接与 SELECT 的 db）、`M.last_response`、`M.TITLE = "PosteRedis"` | poste-db state.lua |
| `constants.lua` | URL 前缀判定、结果高度比例、`MAX_PREVIEW_BYTES`、命令黑名单（M1 仅常量定义，P2 启用） | poste-db constants.lua |
| `toml.lua` | vendor 自 poste-db/toml.lua，文件头注明来源 commit | D5 |
| `connections.lua` | `M.find_connections_toml(dir)`（walk-up + mtime 缓存）、`M.get_connection_config(name)`、`M.resolve_redis_url(name)` → `url, err`、`M.list_connections(cb)`；解析规则见 §5 | poste-db connections.lua（剥掉 UI 菜单与 SQL 专有字段） |
| `parser.lua` | **唯一解析器（D1）**。`M.extract_entries(lines) → entries[]`：entry = `{kind="command"\|"use", tokens, start_line, end_line, raw}`（续行已拼接、引号已按状态扫描、行内 `#` 已剥离）；`M.cursor_entry(buf)`、`M.visual_entries(buf)`、`M.file_entries(buf)`、`M.entry_text(entry)`；`M._test` 暴露全部 | 新写（spec 驱动）；statement.lua 的"光标/可视"入口形态 |
| `exec_run.lua` | `M.run_async(entries, opts, callbacks)`：组 `{connection, commands}` JSON → `jobstart({"poste","redis-exec","--json"}, {stdin="pipe"})` → `chansend`/`chanclose(id,"stdin")` → 逐行 `type` 分发（progress 忽略或更新 spinner，result/summary 进回调）；`exec_seq` 防 stale；callbacks pcall + `vim.schedule`；同步版 `M.run(entry, opts)` 用 `poste.cli.run_json`（信息类） | poste-db exec_run.lua |
| `format.lua` | `M.format_result(result_event) → {lines, meta}`：value.type 分派——string/int/nil/status 直出，array → 对齐表格（index 列），map → field/value 表，binary → hex 摘要 + 字节数；`M.format_error(err)`；`M.preview_json(value)` | 新写（形态参照 poste-db format.lua，无分页） |
| `buffer.lua` | 结果面板：`M.render(results, opts)`（`poste://redis_result`，底部 split，每命令一个 tab：状态行 + 正文，tab 行显示命令与耗时）；`M.next_tab/prev_tab`；`M.preview_raw()`（`K` → float，来自 poste-ai float_window 模式）；`M.is_open/close` | poste-db buffer/init.lua 的最小子集 + poste-ai buffer/nav_preview.lua |
| `history.lua` | `M.push(entry)`、`M.list()`、`M.toggle()`（win-relative float：j/k/CR/q）——M1 内存态，不落盘 | poste-db buffer/history.lua |
| `indicators`/`statusline` | M1 直接用 `poste.indicators.set_indicator`；statusline M2 再做 | poste 共享 |
| `highlights.lua` / `syntax.lua` | `PosteRedis*` 组；regex 高亮规则：命令名（内置 Redis 命令词表，取RESP 常用 ~190 条）、`USE` 行、字符串、数字、注释 | poste-db highlights + syntax/poste_sql.vim |
| `autocmds.lua` / `buffer_setup.lua` / `commands.lua` / `health.lua` | FileType `poste_redis` 接线（keymap/treesitter 尝试注册/语法启用）；命令注册（§6）；health（nvim≥0.10、poste.state、二进制 + `--version`、redis 段连接、`redis-exec` 冒烟 `PING`） | poste-db 同名文件 |
| `init.lua` | `M.setup(opts)`：config.merge → highlights → autocmds → commands → setup_existing_buffers | poste-db init.lua |

**M1 明确不建**：`browser/`、`value/`、`session_conn.lua`、`editor/`、`import/export`、AI 接入、statusline。

### 4.1 关键签名（防歧义）

```lua
-- parser.lua
M.extract_entries(lines: string[]) -> entry[]   -- entry.kind: "command"|"use"
M.cursor_entry(buf: number) -> entry|nil        -- 光标所在 entry（跨续行）
M.visual_entries(buf: number) -> entry[]        -- 可视选区覆盖的 entries（有序去重）

-- exec_run.lua
M.run_async(entries: entry[], opts: { connection: string }, cbs: {
  on_result = fun(result_event),     -- 每命令一条（含 status="error"）
  on_summary = fun(summary_event),
  on_error = fun(msg, stderr),       -- 进程级失败（连接失败等）
}) -> job_id

-- format.lua
M.format_result(result_event) -> { lines: string[], meta: { command, seq, status, latency_ms } }

-- buffer.lua
M.render(results: result_event[], meta: { src_buf, connection }) -> nil
```

### 4.2 解析规则测试矩阵（parser spec 必须覆盖）

单命令行；续行拼接（`\` 结尾，含末尾空白）；`"a # b"` 引号内 `#` 不切注释；`'it''s'` 单引号字面量；裸词；`USE name` / `USE`（空）→ use entry；`--` 与 `#` 整行注释；空行；大小写命令（`get` ≡ `GET`）；空文件 → 空 entries；CRLF 行尾。

### 4.3 `redis_value_to_json` 需补的形状（Rust 工作项内完成）

```json
{"type":"array","items":[...],"len":150,"truncated":true}     -- 超过 max_payload 截断时
{"type":"map","entries":[["field","value"],...],"len":80}
{"type":"binary","encoding":"hex","bytes":2048,"preview":"48 65 6c..."}   -- 前置 64 字节
```

---

## 5. `connections.toml` redis 段规格

与 SQL 段同文件共存，按段名引用；`dialect = "redis"` 是识别标记。

```toml
[my-redis]
dialect = "redis"
url = "redis://:{{REDIS_PASS}}@127.0.0.1:16379/0"   # 形式一：完整 URL（推荐）
# color = "MiniStatuslineModeReplace"               # 可选，状态栏配色（M2 生效）

[my-redis-fields]                                    # 形式二：分字段（url 缺省时生效）
dialect = "redis"
host = "127.0.0.1"
port = 6379
username = "default"        # 可选，Redis 6+ ACL
password = "{{REDIS_PASS}}" # 可选
db = 0                      # 可选，默认 0
# tls = true                # 可选，P3 实现；true 时 scheme 用 rediss://
```

- **解析优先级**：`url` 字段存在即用（`{{var}}` 展开后）；否则由 host/port/username/password/db/tls 拼接
- **`{{var}}` 展开**：复用家族机制——OS env > `.env` > `env.json`（vendored 展开函数随 toml.lua 一起搬）
- **校验**：无 host/url、URL 无 scheme、scheme 非 redis://|rediss:// → `resolve_redis_url` 返回 `nil, err`
- **URL 里直接带 db**（`/0`）与分字段 `db` 都允许；session/exec 均按 URL 透传给 Rust

---

## 6. 命令与快捷键总表（M1 默认值）

### 命令

| 命令 | 说明 |
|------|------|
| `:PosteRedisConnection` | 连接选择器（poste.select），选中即设为当前并写入 state |
| `:PosteRedisRunFile [file]` | 整文件执行（缺省当前 buffer） |
| `:PosteRedisHistory` | 历史浮窗 |
| `:PosteRedisInfo` | 环境/连接/二进制信息 |
| `:checkhealth poste-redis` | 健康检查 |

### 快捷键（`config.keymaps` section）

| section | action | 默认 | 说明 |
|---------|--------|------|------|
| `redis_source` | `run` | `<CR>`（n+v） | 执行光标/选区命令 |
| `redis_source` | `history` | `<leader>rh` | 历史浮窗 |
| `redis_source` | `help` | `g?` | 键位帮助 |
| `redis_result` | `close` | `q` | 关闭面板 |
| `redis_result` | `next_tab` / `prev_tab` | `<Tab>` / `<S-Tab>` | 切换结果 tab |
| `redis_result` | `preview_raw` | `K` | 原始 JSON 浮窗 |
| `redis_result` | `yank` | `yy` | 复制当前结果正文 |

用户覆盖走 `setup({ keymaps = { redis_source = { run = "<leader>x" } } })`，`false` 禁用。

---

## 7. M1 任务分解（顺序执行，每项完成即 commit）

| # | 工作项 | 产出 | 验证 |
|---|--------|------|------|
| 1 | 仓库脚手架（§1 清单） | 全部模板文件 | `tests/run.sh` 空跑通过 |
| 2 | Rust：redis 依赖 + `redis_executor.rs` 移植（含 parse_shell_args / redis_value_to_json 及单测、truncated 扩展） | `cargo test` 绿 | `cd ../poste.nvim && cargo test -p poste-exec` |
| 3 | Rust：`redis-exec` 子命令（stdin 契约 §3.2）+ `#[ignore]` 集成测试 | 冒烟 `echo '{"connection":"redis://127.0.0.1:16379/0","commands":[["PING"]]}' \| poste redis-exec --json` 输出 PONG 事件 | 手动 + 集成测试 |
| 4 | Lua：config/state/constants/highlights/syntax/ftdetect/ftplugin | 高亮可见 | 打开 .redis 文件目检 |
| 5 | Lua：toml.lua（vendor）+ connections.lua | redis URL 解析 | connections spec（含 {{var}}、双形式、错误路径） |
| 6 | Lua：parser.lua | 唯一解析器 | §4.2 测试矩阵全绿 |
| 7 | Lua：exec_run.lua + format.lua | 事件消费与渲染 | spec：stub 事件序列 fixture（progress/result 错误混合/summary） |
| 8 | Lua：buffer.lua + history.lua | 结果面板 + 历史 | spec：多 tab 渲染、切换、K 预览 |
| 9 | Lua：autocmds/buffer_setup/commands/health/init 接线 | `<CR>` 端到端可用 | 手动：docker redis 上跑示例文件 |
| 10 | AGENTS.md + `docs/dev/file-index.md` + `.opencode/skills/redis/SKILL.md` | agent 上下文齐备 | — |
| 11 | 验收清单（§8）逐条过 | M1 出口 | — |

---

## 8. M1 验收清单（对应 requirements §5 P0）

- [ ] `.redis` 文件：光标任意命令行 `<CR>` 执行（含续行拼接、引号内 `#` 不误切）
- [ ] visual 选区多条命令顺序执行，逐条出结果 tab
- [ ] 整文件执行：greedy——第 2 条失败不阻断第 3 条，summary 标注 failed
- [ ] `USE my-redis` 后续命令打到该连接；连接缺失时明确报错并提示 `:PosteRedisConnection`
- [ ] `connections.toml` 双形式解析 + `{{var}}` 展开 + `.env` 生效；密码不出现在任何日志/`messages`
- [ ] 五种值形态渲染正确：`(nil)` / 整数 / 状态串 / 数组表 / map 表；二进制为 hex 摘要
- [ ] 结果面板 `<Tab>`/`<S-Tab>` 切换、`K` 原始 JSON、`q` 关闭后重开内容不丢
- [ ] 执行中 spinner 可见、可 `Esc` 取消且 busy 状态干净（连按两次 `<CR>` 第二次被拒并有提示）
- [ ] 历史：命令、连接、状态、耗时可见
- [ ] `:checkhealth poste-redis`：二进制缺失/版本过旧（无 redis-exec 子命令）时给出构建指引
- [ ] 全部 plenary spec + cargo test 绿；CI（sibling poste.nvim + redis service）绿

---

## 9. 红线（执行期间随时对照）

1. 不 require 任何卫星模块（poste-db/poste-http/poste-ai 运行时零耦合；AI 接入是 M2+ 且只 pcall）
2. 不改 `.redis` 语法的"一行一命令"裁决；不在 Rust 侧加文件解析
3. 不把密码写进任何持久化文件、日志、历史记录
4. 主线程零阻塞：一切 IO 回调化；stale 一律 epoch/seq 丢弃；busy 状态每条 early-return 必清
5. 危险命令（FLUSHALL/FLUSHDB/SHUTDOWN）M1 就在 parser 层标记（结果面板黄色提示），黑名单拦截在 P2 完整实现
