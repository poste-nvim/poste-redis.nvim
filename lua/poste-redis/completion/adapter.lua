--- Completion adapter for poste-redis.
---
--- Wraps blink.cmp behind a stable interface (poste-db completion adapter
--- pattern, rebuilt for redis — no cross-satellite require). All completion
--- wiring goes through this module instead of requiring blink.cmp internals.
local M = {}

-- Lazy-load blink.cmp, returning nil if not available.
local function blink()
  local ok, mod = pcall(require, "blink.cmp")
  return ok and mod or nil
end

-- Lazy-load blink.cmp.completion.trigger
local function blink_trigger()
  local ok, mod = pcall(require, "blink.cmp.completion.trigger")
  return ok and mod or nil
end

--- Check if blink.cmp is available.
function M.is_available()
  return blink() ~= nil
end

--- Register a source provider in blink.cmp.
--- @param opts { name: string, module: string, label?: string, score_offset?: number, min_keyword_length?: number, should_show_items?: boolean, async?: boolean }
function M.register_source(opts)
  local b = blink()
  if not b then return end
  b.add_source_provider(opts.name, {
    module = opts.module,
    name = opts.label or opts.name,
    async = opts.async ~= false,
    score_offset = opts.score_offset or 1000,
    min_keyword_length = opts.min_keyword_length or 0,
    should_show_items = opts.should_show_items ~= false,
  })
end

--- Map a filetype to a source name.
function M.register_filetype(ft, source_name)
  local b = blink()
  if not b then return end
  b.add_filetype_source(ft, source_name)
end

--- Show the completion menu (used by the <C-Space> trigger keymap).
--- @param opts table|nil
function M.show(opts)
  local b = blink()
  if b and b.show then
    b.show()
    return
  end
  local trigger = blink_trigger()
  if trigger then
    trigger.show(opts or { force = true })
  end
end

return M
