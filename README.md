# poste-redis.nvim

Redis for Neovim in the [Poste](https://github.com/beyondlex/poste.nvim) plugin family —
write Redis commands in a `.redis` buffer, hit `<CR>`, and read the results in a result
panel. The key browser and value viewer are already included.

**Status: M1 complete (file execution loop).** See
[requirements.md](requirements.md) and [EXECUTION-PLAN.md](EXECUTION-PLAN.md).

## Install

With lazy.nvim:

```lua
{
  "beyondlex/poste-redis.nvim",
  dependencies = { "beyondlex/poste.nvim" },
  opts = {},
}
```

Connections live in the project `connections.toml`:

```toml
[my-redis]
dialect = "redis"
url = "redis://:{{REDIS_PASS}}@127.0.0.1:6379/0"
```

## Usage

```redis
USE my-redis
SET session:abc "token" EX 3600
GET session:abc
```

`<CR>` executes the command under the cursor; results render in a result panel;
`:PosteRedisHistory` shows past runs.

## Next

Current follow-ups are the P2 items from `requirements.md`:

1. Write operations
2. Command palette and dangerous-command guard
3. Completion
4. Export tooling

## License

MIT
