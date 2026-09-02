--- poste-redis AI integration — registers a "redis" context on poste-ai.nvim
--- (optional dependency). Zero coupling: poste-ai is never required at load
--- time; registration is attempted in setup() and on :PosteRedisChat.
---
--- The chat's ```redis codeblocks execute against the current context
--- connection (poste-redis.ai.actions.execute_redis) and render in the same
--- result panel as manual execution — so an AI agent can design and demo
--- things like a redis leaderboard (ZADD / ZINCRBY / ZRANGE) inside a folder.

local redis_state = require("poste-redis.state")

local M = {}

--- True when poste-ai.nvim is on the runtimepath.
function M.available()
  return (pcall(require, "poste-ai")) and true or false
end

--- Register (or refresh) the "redis" context. Returns false when poste-ai is
--- not installed; callers decide whether that is worth telling the user.
--- @return boolean
function M.register()
  local ok, poste_ai = pcall(require, "poste-ai")
  if not ok then return false end
  poste_ai.register_context("redis", {
    system_prompt = function(scope)
      return require("poste-redis.ai.system_prompt").build(scope)
    end,
    commands = require("poste-redis.ai.commands").list(),
    codeblock = {
      langs = { "redis" },
      confirm = function(code)
        return require("poste-redis.ai.actions").confirm_redis(code)
      end,
      execute = function(code, refs, cb)
        require("poste-redis.ai.actions").execute_redis(code, refs, cb)
      end,
    },
  })
  return true
end

--- Notify and report absence of poste-ai. Returns true when available.
local function ensure_available()
  if M.available() then return true end
  vim.notify("PosteRedis AI chat needs poste-ai.nvim (beyondlex/poste-ai.nvim) installed.",
    vim.log.levels.WARN, { title = redis_state.TITLE })
  return false
end

--- Open the AI chat with the redis context active.
function M.open_chat()
  if not ensure_available() then return end
  M.register()
  local poste_ai = require("poste-ai")
  poste_ai.set_active_context("redis")
  poste_ai.chat("redis")
end

return M
