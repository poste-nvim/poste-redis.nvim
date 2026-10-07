# poste-redis.nvim 需求规格说明书

**版本**: 2.0.0
**状态**: 已实现（M1/M2 均已落地并通过测试；本文保留为需求记录，当前架构以 AGENTS.md 与 `docs/dev/` 为准）
**日期**: 2026-08-31
**前身**: 1.0.0 草案（ARDM 对标式设计，本文修正其架构与范式定位）
**配套**: 执行规格见 **EXECUTION-PLAN.md**（M1 工作单——AI agent / 开发者从那里开始动手，冲突时以它为准）

---

## 1. 目标与定位

### 1.1 一句话定位

Poste 家族第三个协议卫星：让 vim 党**在 `.redis` 缓冲区里写 Redis 命令、`<CR>` 执行、结果进结果面板**，并提供一个键驱动的 Key 浏览器作为辅助入口。

### 1.2 与 Poste 家族的关系（架构基线，非可选）

```
poste.nvim（共享 infra + Rust CLI）        poste-ai.nvim（AI 助手，零依赖）
        ↑ 硬依赖（rtp + binary）                  ↑ 可选依赖（pcall）
        └────────────────── poste-redis.nvim ─────┘
```

> **2026-09-13 更新**：上图是 M1 立项时的基线。家族解散后共享 infra 已
> vendor 进本仓库，rtp 依赖不复存在；仅剩 `poste` 二进制（NDJSON schema
> 见 `../poste.nvim/docs/schema.md`）。

- 与 **poste-db.nvim 完全同构**：Lua 卫星（`lua/poste-redis/`）+ poste 二进制扩展。不做独立后端、不自造 RPC 协议
- **红线**：禁止 `require("poste.http.*")` / `require("poste.db.*")`；AI context 只 `pcall(require, "poste-ai")`
- **命名**：`poste-redis`（插件/命令 `:PosteRedis*`）/ `poste_redis`（snake_case 标识符、namespace）/
  `poste_redis`（filetype —— 与 poste_http/poste_sql 同款三段式）
- 家族惯例照单全收：`config.get_keymap` section 化快捷键、`state.get_keymap` 回落、
  `poste://` scratch buffer 命名、`vim.notify` 带 title、plenary 测试 + `tests/run.sh`、
  `docs/dev/file-index.md` + `.opencode/skills/`、`LEARNINGS.md`

### 1.3 范式声明（对 1.0 草案的核心修正）

1.0 草案对标 ARDM（浏览驱动）。本版定位：**文件执行范式是一等公民，浏览器是配角**。理由：
- `.redis` 缓冲区天然继承 modal 编辑的全部能力（宏、marks、`/` 搜索、可视模式批量执行）
- 与 poste-db 交互习惯完全一致，vim 党零学习成本
- poste-core parser **已原生支持 Redis**（`Protocol::Redis`、`@connection redis://` 指令、首 token 即命令）——文件范式是顺着已有地基建，浏览器反而是新工程

---

## 2. 架构

### 2.1 分层

```
+--------------------------------------------------------------+
| Neovim                                                       |
|  lua/poste-redis/                                            |
|   execution/  解析执行链（statement → executor → 渲染）      |
|   browser/    Key 浏览器（tree/async/actions，仿 db_browser）|
|   value/      值渲染（五类型 + 大值策略 + 二进制）           |
|   commands/state/config/highlights/health                    |
+---------------------------+----------------------------------+
                            | jobstart / JSON-lines（既有模式）
+---------------------------v----------------------------------+
| poste 二进制（crates/，Rust）                                 |
|  `poste redis-exec`           单次/多命令，stdin JSON 进，     |
|                               逐行事件流出（同 SQL 事件键）    |
|  `poste redis-session`        长驻：连接保持、SELECT 状态、   |
|                               MONITOR/PubSub 推送（JSON 行） |
|  移植自 poste-data-modification：execute_redis +             |
|  redis_value_to_json（已实现，redis 0.27）                    |
+--------------------------------------------------------------+
```

### 2.2 传输协议（对 1.0 草案的核心修正）

**不引入 MessagePack-RPC、daemon、TCP socket。** 家族已有两级传输，直接沿用：

| 传输 | 形状 | 用途 |
|------|------|------|
| `exec-file` 扩展 | 单次进程，stdout 逐行 JSON 事件（`progress\|result\|summary`，参照 poste-db `exec_run.lua`） | 文件执行、单命令 |
| `redis-session`（新） | 长驻进程，stdin/stdout 逐行 JSON：请求 `{seq, connection, command[]}`，响应 `{seq, result}`；推送事件 `{event: "monitor"/"pubsub", payload}`（参照 poste-db `session_conn.lua` + poste-ai `context_client.lua`） | 会话保持（SELECT 状态、连接复用）、MONITOR/PubSub |

连接管理是 **Lua 侧解析 `connections.toml` → 传 `redis://` URL 给二进制**（与 poste-db 相同，二进制不读配置文件）。

### 2.3 复用清单（已完成资产 → 本插件用途）

| 资产 | 来源 | 用途 |
|------|------|------|
| `Protocol::Redis` + `@connection redis://` 解析 | poste-core parser（已就绪） | `.redis` 文件解析基座 |
| `execute_redis` + `redis_value_to_json` | poste-data-modification（已实现） | 移植进 poste.nvim crates 即得 P0 执行能力 |
| `exec-file` JSON 事件流 / `session` 线协议 | poste.nvim crates | 两级传输，零新协议 |
| `connections.toml` + `{{var}}`/`.env` + walk-up + mtime 缓存 | poste-db `connections.lua` | 连接管理（redis 段） |
| `db_browser/` tree/async/actions 三件套 | poste-db | Key 浏览器骨架（M2，照抄模式重建） |
| `format.lua` / 数据集面板 / history 的**交互形态** | poste-db | 命令结果面板、请求历史（**自建精简版**，见下） |

> **"复用"的含义**：指照抄设计、移植代码并按家族命名规范改名——**运行时严禁跨卫星 require**
> （家族红线，poste-http 先例）。M1 结果面板为 poste-redis 内自建的单 buffer + tabs 精简版，
> 不搬运数据集的分页/编辑/筛选。"复用清单"逐项的落地位置见 EXECUTION-PLAN.md。
| `indicators.lua` spinner、`select.lua`、`dialog.lua`、`float_window.lua` | poste 共享 / poste-db | UI 积木 |
| context 注册契约 | poste-ai `context_api.lua` | AI 助手接入（§9） |
| grammar.js + install.lua 编译发布 | poste-http | `.redis` 语法高亮（§4，已实现并保留 regex fallback） |

---

## 3. `.redis` 文件语法设计

> 1.0 草案沿用 SQL 的 `@connection/@database/###` 分组。本版按 Redis 特性重新设计：
> **一行一命令、`#` 注释、`USE` 切连接、`\` 续行**。语法对齐 redis-cli 心智模型，不发明第二套方言。

### 3.1 文件示例

```redis
# ── 连接与库 ──────────────────────────────
USE my-redis          # 切换连接（非 Redis 命令，本插件指令）
SELECT 3              # 真·Redis 命令：切 db；session 模式下状态保持

# ── String ──
SET session:abc "eyJhbGciOi..." EX 3600
GET session:abc

# ── Hash：长命令用 \ 续行 ──
HSET user:42 name "Alice" \
      email "alice@example.com" \
      age 30
HGETALL user:42

# ── ZSet ──
ZADD board 99 alice 87 bob
ZREVRANGE board 0 9 WITHSCORES

# ── 引号规则：双引号（JSON 兼容转义）、单引号、裸词 ──
LPUSH queue:email '{"to":"a@b.c","tpl":"welcome"}'
DEL user:41 user:42 user:43
```

### 3.2 语法规则

| 规则 | 定义 |
|------|------|
| 命令 | 每行一条：首 token 为命令名（大小写不敏感），其余为参数 |
| 参数 | 裸词（到空白为止）/ 双引号串（`\` 转义，JSON 兼容）/ 单引号串（字面量）/ 数字 |
| 续行 | 行尾 `\`，拼接后仍按单命令解析 |
| 注释 | 行首 `#` 或 `--`；行尾 `#` 后内容为行内注释（**带引号内 `#` 不算**——解析器按引号状态扫描） |
| 连接指令 | `USE <name>`：切换后续命令的连接（name 对应 `connections.toml`）；`USE` 单独成行 = 弹出连接选择器 |
| db 切换 | 原生 `SELECT <n>`，session 模式下二进制保持 db 状态（这是长驻连接的真实红利） |
| 空行 | 忽略 |
| 明确不做 | `###` 分组、`@database`、多命令拼接分隔符——一条命令一行已经足够清晰 |

### 3.3 执行语义

- `<CR>`（normal）：执行光标所在命令；`<CR>`（visual）：执行选中的多条（顺序、逐条出结果）
- `:PosteRedisRunFile`：整文件执行，progress 对话框 + 每条命令一个结果标签页（复用数据集 tabs）
- 结果：redis-cli 风格渲染进结果面板（结构化 JSON 在底层，`K` 预览原始 JSON）
- 历史：每次执行入 history（复用数据集 history 模型）

### 3.4 语法高亮方案

**结论：本仓库已自带 tree-sitter grammar**，并保留 regex fallback 作为兼容路径。
方案按家族先例（poste-http 自带 grammar）分两步：

| 阶段 | 方案 | 说明 |
|------|------|------|
| M1 | **regex 兜底**：`syntax/poste_redis.vim` | 命令名列表（内置 Redis 命令表）、字符串、注释、`USE` 指令四类 match 即可，当天可用；poste-db 同款 legacy 姿势 |
| M2 | **自带 grammar**：`grammar.js` + `queries/poste_redis/highlights.scm` | 照抄 poste-http 的 `install.lua`（编译进 `stdpath("data")/site/parser`，health 报告编译器缺失）；`vim.treesitter.language.register("poste_redis", ...)`；filetype 由 `ftdetect/poste_redis.vim`（`*.redis`）设置 |

grammar 节点与捕获（M2）：

```
source_file    := (comment | use_directive | command)*
comment        -> @comment
use_directive  := "USE" connection_name     -> @keyword / @label
command        := command_name arg*         -> @keyword.command / 参数按类型
arg            := bareword | string | number | flag
string         -> @string（JSON 探测留给运行期，grammar 不做 injection——M3 再评估）
number         -> @number
```

M3 候选：对 JSON 串做 `injection` 高亮（依赖 markdown fence 注入经验）；completion source
（`completion/data.lua` 模式：内置命令表 + 连接名 + 光标处 key 提示）。

---

## 4. 数据契约

### 4.1 执行请求/响应

- Lua → `exec-file`/`redis-session`：`{ seq, connection: "<redis://url>", command: ["GET", "user:42"] }`
  （URL 由 Lua 按 `connections.toml` 解析，含 `{{var}}` 展开；二进制不读配置文件）
- 二进制 → Lua（事件流，逐行 JSON）：

```json
{"type":"progress","index":1,"total":2,"command":"GET user:42"}
{"type":"result","seq":1,"command":"GET user:42","status":"\"Alice\"","latency_ms":2,
 "value":{"type":"string","value":"Alice"}}
{"type":"result","seq":2,"command":"HSET bad key","status":"error","error":"WRONGTYPE ..."}
{"type":"summary","total":2,"failed":1,"elapsed_ms":5}
```

键名用 `"type"`（与 SQL `exec-file` 事件流一致，Lua 侧事件循环同构）；单命令失败是
`status:"error"` 的 result 事件（greedy 继续），进程级失败（连接失败）走 stderr + 非 0 退出。

### 4.2 值形状（沿用 `redis_value_to_json`，需补字段）

```json
{"type":"string|integer|nil|bulk|array|set|map|status|binary",
 "value": ..., "parsed": <JSON 自动探测成功时的对象>, "binary": {"bytes": 1024, "encoding": "hex|base64"}}
```

M2 需为浏览场景扩展：`{"type":"array","items":[...],"len":N,"truncated":bool,"cursor":...}`
（分页拉取标记）。二进制值默认 hex 摘要 + 长度，全量按需加载。

---

## 5. 功能规格（P0–P3，含验收标准）

### P0 — 文件执行闭环（M1，本插件成立的底线）

| # | 需求 | 验收 |
|---|------|------|
| P0-1 | `.redis` filetype + regex 高亮 + `USE`/`SELECT`/注释/续行解析 | 光标置任意命令行 `<CR>` 正确提取单条命令（含续行拼接、引号内 `#`） |
| P0-2 | 连接：`connections.toml` redis 段（`url` 或 `host/port/password/db` 字段）、`USE` 指令、`:PosteRedisConnection` 选择器（复用 poste-select）、状态栏连接名+db | 执行打到的连接与 `USE` 一致；`{{var}}` 正确展开；密码不进日志 |
| P0-3 | 执行管线：`poste redis-exec` 子命令（stdin 契约见 EXECUTION-PLAN §3.2）；`<CR>`/visual/整文件三入口；spinner；`exec_seq` 防 stale；错误行标红（复用 indicators/extmark） | 多命令文件执行不冻结 UI；第 2 条失败不中断第 3 条（mode=greedy）；结果标签页可切换 |
| P0-4 | 结果渲染：redis-cli 风格状态行 + 数组表格（复用 format/dataset），`K` 预览原始 JSON | `HGETALL` 渲染为 field/value 表；`(nil)`/`OK`/整数/二进制摘要各有稳定呈现 |
| P0-5 | 历史：命令、连接、状态、耗时 | `:PosteRedisHistory` 可回看 |
| P0-6 | `:checkhealth poste-redis`：nvim 版本、二进制、redis 段连接、编译器（M2 前提示） | 缺二进制时给出可执行的修复指引 |

### P1 — Key 浏览器 + 值查看（M2）

| # | 需求 | 验收 |
|---|------|------|
| P1-1 | 浏览器窗口（照抄 db_browser：侧栏 split 可配、`poste://redis_browser`）：连接节点 → db 节点（SELECT n，`--scan` 枚举库）→ key 列表/树 | 10 万 key 的库：SCAN 分批加载，**UI 不冻结，首屏 < 300ms**（验收脚本实测） |
| P1-2 | 过滤：`/` 输入 pattern（`SCAN MATCH`，非 KEYS）；树视图按 `:` 前缀折叠/展开，可切平铺 | 过滤期间可取消；翻页 cursor 正确续传 |
| P1-3 | 值查看：`<CR>` 打开值面板——TYPE 先行，按类型渲染 String（原始/HEX/Base64 视图切换）、Hash（表）、List/Set/ZSet（列表，ZSet 带 score 列）、每屏尾部显示总数/已加载数 | Hash 1 万 field：HSCAN 分页拉取；`K` 预览原始值；大 String（>64KB）默认截断 + 按键全量加载 |
| P1-4 | TTL 显示与修改（`TTL`/`PERSIST`/`EXPIRE`）；删除（单条/批量选中/按前缀，**统一确认框**）；重命名（`RENAME` 冲突检测） | 按前缀删除前显示匹配数量预估并二次确认 |
| P1-5 | `redis-session` 长驻传输落地：连接复用、SELECT 状态保持、空闲回收、断线自动重启（照抄 session_conn） | 同一浏览器会话内连续操作复用同一连接（`CLIENT INFO` 验证）；进程被杀后下一次操作自动恢复 |
| P1-6 | tree-sitter grammar（`grammar.js` + highlights + install.lua），regex 降级可用 | 无 C 编译器环境：health 警告 + regex 高亮自动生效 |

### P2 — 写操作与运维面板（M3）

| # | 需求 |
|---|------|
| P2-1 | 值编辑：String 直接编辑 buffer → SET；Hash field 增删改；List LSET/LPUSH/RPUSH/LREM；ZSet score 修改。全部走确认（`confirm_sql` 同款启发式：写命令必确认） |
| P2-2 | 命令面板：浮窗输入任意命令（shell-args 解析），结果进面板；危险命令（FLUSHALL/FLUSHDB/SHUTDOWN/CONFIG SET）黑名单 + 显式解锁 |
| P2-3 | MONITOR / PubSub：`redis-session` 推送事件 → 专用 buffer 实时滚动（复用 context_client 推送模式）；订阅频道管理 |
| P2-4 | 补全：blink adapter——命令表、USE 连接名、光标 key 前缀候选（SCAN MATCH 补全） |
| P2-5 | 导出：选中 key 集合导出 JSON/Redis 命令回放脚本（`DUMP`+`RESTORE` 或 type-aware 重建命令） |

### P3 — 远期（M4，逐项评估，默认不做）

Cluster / Sentinel / TLS、ReJSON 类型专属视图、内嵌 redis-cli 终端（依赖用户本机 redis-cli）、
内存分析（MEMORY USAGE 聚合 + 前缀维度统计）、导入（JSON/CSV → 写命令）、自定义解码器钩子、
key 书签（`ma`/`'a`）。SSH 隧道**不做**——`ssh -L` 端口转发 + `connections.toml` 指向本地端口即可，
文档写清这个姿势。

---

## 6. 非功能需求

| 维度 | 要求 |
|------|------|
| 异步 | 一切 Redis IO 经 jobstart 回调；主线程零阻塞；所有回调 `pcall` + `vim.schedule` + seq/epoch 防 stale |
| 取消 | 任意长操作可 `<Esc>`/`q` 取消；取消后 UI 状态一致（busy 必清——家族头号卡死教训） |
| 稳健 | 连接失败/认证失败/WARNINGTYPE 错误有明确 notify 与结果面板呈现；二进制崩溃自动重启（session_conn 模式） |
| 大值 | 默认截断预览（阈值 64KB），按需全量；二进制值 hex 摘要优先，防 buffer 灌入垃圾字节 |
| 安全 | 危险命令确认/黑名单（§5 P2-2）；密码只存在于 `{{var}}` 展开后的内存 URL，日志 redact（复用 log.redact_url） |
| 性能 | 结果渲染走 dataset 既有分页/虚拟化路径；浏览器 SCAN COUNT 默认 500，可配 |

---

## 7. 里程碑

| 里程碑 | 内容 | 出口标准 |
|--------|------|----------|
| M1 文件执行闭环 | Rust：移植 `execute_redis` + 新增 `redis-exec`；Lua：解析器/连接/执行/结果面板/历史/health/regex 高亮 | §5 P0 全部验收通过；docker redis 集成测试绿 |
| M2 浏览器与查看 | `redis-session`、浏览器、五类型值查看、TTL/删除/重命名、tree-sitter | §5 P1 全部验收；10 万 key 验收脚本 |
| M3 写与运维 | 值编辑、命令面板、MONITOR/PubSub、补全、导出 | §5 P2 验收；危险命令黑名单测试 |
| M4 按需 | P3 逐项评估 | 单独立项 |

---

## 8. 测试与交付

- **Lua**：plenary（`tests/run.sh`，隔离 XDG）——解析器 fixture、连接解析、值渲染、浏览器 tree 逻辑（stub 传输层）、session 重启逻辑；spec 文件按模块一一对应
- **Rust**：cargo test——命令行解析（引号/转义/续行）、`redis_value_to_json` 各类型、错误路径；集成测试连 docker redis（`docker-compose.yml` 加 redis:7 服务，测试前后清库）
- **CI**：同 poste-db 形状（checkout poste.nvim 为 sibling，起 redis 服务容器）
- **文档**：`docs/dev/file-index.md` + `.opencode/skills/redis/SKILL.md`；用户文档进 doc-poste 站点（`src/content/docs/poste-redis/`）
- **交付**：GitHub Releases（二进制由 poste.nvim 统一发版，本插件不独立发二进制）

---

## 9. AI 接入（赠品，M2 之后）

poste-ai 的 context 契约现成，redis context 照 poste-db 的 `lua/poste-db/ai/` 四件套实现：

- `@my-redis/3` 引用（连接/库）→ `resolve` 注入 db 摘要（key 前缀统计 + 类型分布，SCAN 聚合，不注入值）
- system_prompt：本插件命令/快捷键知识 + 常用 Redis 命令语义
- codeblock：AI 回复的 ```redis 块 `<CR>` 执行进结果面板（写命令确认策略同 P2-1）

---

## 10. 风险与缓解

| 风险 | 缓解 |
|------|------|
| 二进制 redis 能力滞后于 Lua 侧 | M1 从移植 `execute_redis` 起步（已验证实现），Lua 侧全程 stub 传输层开发，不被 Rust 进度阻塞 |
| MONITOR/海量 key 的推送洪峰 | 浏览器侧 SCAN 分批 + 丢弃过期 epoch；MONITOR buffer 环形截断（保最近 N 行） |
| 写操作误删 | 一切写命令确认；前缀删除二次确认 + 数量预估；FLUSH 类黑名单 |
| tree-sitter 编译环境缺失 | regex 兜底自动生效；health 明确提示 |
| `USE`/`SELECT` 语义混淆 | 文档强调：USE=本插件切连接，SELECT=原生切 db；状态栏同时显示两者 |
