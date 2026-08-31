# poste-redis 手动测试示例

## 准备

1. 启动本地 redis（playground 的 docker-compose，端口 16479）：

   ```bash
   docker compose -f playground/docker-compose.yml up -d
   ```

2. 确认 poste 二进制已构建（含 `redis-exec`）：

   ```bash
   cd ../poste.nvim && cargo build --release
   ```

3. 用 nvim 打开 `examples/` 下的任意 `.redis` 文件（filetype 自动识别为
   `poste_redis`，`<CR>` 键位已绑定）。

## 测试文件

| 文件 | 覆盖 |
|------|------|
| `demo.redis` | 需求文档 §3.1 全示例：USE/SELECT、String/Hash/List/Set/ZSet、续行、引号内 `#`、清理 |
| `parser_edges.redis` | 解析器边界：续行、引号内 `#` 不算注释、行内注释、大小写不敏感、危险命令 |
| `rendering.redis` | 值渲染：二进制（EVAL 构造）、空集合、stream、整数/状态 |
| `multi_use.redis` | 连接切换：USE 切连接、裸 USE 弹选择器、无 USE 报错 |

## 操作

- 光标任一行 `文件: <CR>` → 执行该命令，结果进底部面板
- 可视选中多行 `<CR>` → 顺序执行，逐条出 tab
- `:PosteRedisRunFile` → 整文件执行（按 USE 分段）
- 面板内：`<Tab>`/`<S-Tab>` 切 tab、`K` 预览原始 JSON、`yy` 复制、`q` 关闭
- `:PosteRedisConnection` → 连接选择器；`:PosteRedisHistory` → 历史浮窗
- `:checkhealth poste-redis` → 环境自检

`connections.toml` 中的 `{{REDIS_PASS}}` 等变量从 `.env` / 环境变量展开；
密码只存在于内存 URL，日志一律 redact。
