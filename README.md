# poste-redis.nvim

Redis for Neovim in the [Poste](https://github.com/beyondlex/poste.nvim) plugin family —
write Redis commands in a `.redis` buffer, hit `<CR>`, and read the results in a result
panel. A key browser follows as the second milestone.

**Status: work in progress (M1 — file execution loop).** See
[requirements.md](requirements.md) and [EXECUTION-PLAN.md](EXECUTION-PLAN.md).

## Install (once M1 lands)

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

## Usage (planned M1)

```redis
USE my-redis
SET session:abc "token" EX 3600
GET session:abc
```

`<CR>` executes the command under the cursor; results render in a result panel;
`:PosteRedisHistory` shows past runs.

## License

MIT
