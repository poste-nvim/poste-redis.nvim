--- blink.cmp source registration for poste-redis.
local M = {}

function M.register()
  local adapter = require("poste-redis.completion.adapter")
  if not adapter.is_available() then return end

  adapter.register_source({
    name = "poste_redis",
    module = "poste-redis.completion",
    label = "PosteRedis",
    async = true,
    score_offset = 1000,
    min_keyword_length = 0,
    should_show_items = true,
  })
  adapter.register_filetype("poste_redis", "poste_redis")
end

return M
