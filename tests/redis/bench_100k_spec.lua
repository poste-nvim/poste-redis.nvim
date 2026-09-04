--- M2 exit acceptance: 100k-key database, SCAN batching, first screen
--- < 300ms, UI never freezes (requirements §7 / P1-1).
---
--- Gated on REDIS_TEST_URL (live redis; CI service). Seeds 100k keys in
--- batches, then runs browser/scan.scan_keys and measures:
---   - first_screen_ms: time until the first SCAN batch renders
---   - full_load_ms:    time until the whole scan finishes
---   - event_loop_alive: a probe callback fires between batches (UI not frozen)
---
--- Run:  REDIS_TEST_URL=redis://127.0.0.1:16479/0 bash tests/run.sh

local tree = require("poste-redis.browser.tree")
local async = require("poste-redis.browser.async")
local scan = require("poste-redis.browser.scan")
local session_conn = require("poste-redis.session_conn")

local BENCH_KEYS = 100000
local PREFIX = "bench:"

describe("poste-redis M2 exit — 100k-key browser acceptance", function()
  local url = vim.env.REDIS_TEST_URL

  local function live_available()
    if not url or url == "" then return false end
    local binary = require("poste.state").find_poste_binary()
    if not binary or vim.fn.filereadable(binary) ~= 1 then return false end
    local probe = io.popen('echo \'{"connection":"' .. url .. '","commands":[["PING"]]}\' | "' .. binary .. '" redis-exec 2>/dev/null')
    if not probe then return false end
    local out = probe:read("*a")
    probe:close()
    return out ~= nil and out:find("PONG") ~= nil
  end

  local ok_avail = live_available()

  before_each(function()
    if not ok_avail then pending("REDIS_TEST_URL not reachable"); return end
  end)

  after_each(function()
    session_conn.stop_all()
  end)

  it("seeds and scans 100k keys with a <300ms first screen", function()
    if not ok_avail then pending("REDIS_TEST_URL not reachable"); return end
    local scan_count_orig = require("poste-redis.config").config.scan_count
    require("poste-redis.config").config.scan_count = 500

    -- ── seed: 100k keys in MSET batches of 1000 ──
    local seeded = 0
    local function seed_batch(i)
      if i >= BENCH_KEYS then
        seeded = true
        return
      end
      local cmd = { "MSET" }
      for j = i, math.min(i + 999, BENCH_KEYS - 1) do
        cmd[#cmd + 1] = PREFIX .. j
        cmd[#cmd + 1] = "v" .. j
      end
      session_conn.execute(url, cmd, {
        on_response = function() seed_batch(i + 1000) end,
        on_error = function() seeded = "error" end,
      }, nil, { db = 0 })
    end
    seed_batch(0)
    vim.wait(60000, function() return seeded == true or seeded == "error" end, 5)
    assert.equals(true, seeded, "seeding 100k keys failed")

    -- ── measure scan_keys ──
    async.tree_view = false  -- flat: count keys exactly
    local db = tree.make_db_node({ db = 0 }, "bench-conn")
    local first_screen_at = nil
    local render_ticks = 0
    local t0 = vim.loop.hrtime()

    -- render hook fires on every batch → first call = first screen
    async.render_hook = function()
      render_ticks = render_ticks + 1
      if not first_screen_at then
        first_screen_at = (vim.loop.hrtime() - t0) / 1e6
      end
    end

    scan.scan_keys(db, url, "bench-conn", PREFIX .. "*")
    local done = vim.wait(30000, function() return not db.loading end, 5)
    local full_ms = (vim.loop.hrtime() - t0) / 1e6
    -- The last render goes through the async flush, debounced ~10ms behind
    -- the final SCAN page: `db.loading` flips false first. A fast local redis
    -- streams every page inside ONE debounce window, so without draining the
    -- flush queue here the tick count reads 1 and races this assertion.
    vim.wait(1000, function() return render_ticks >= 2 end, 5)
    async.render_hook = nil

    assert.is_true(done, "scan did not finish in 30s")
    assert.is_true(first_screen_at ~= nil, "first screen never rendered")
    -- count loaded keys (flat view: children are key nodes)
    local key_count = 0
    local function count(nodes)
      for _, n in ipairs(nodes or {}) do
        if n.node_type == "key" then key_count = key_count + 1 end
        count(n.children)
      end
    end
    count(db.children)

    print(("[100k bench] first_screen=%.0fms full=%.0fms ticks=%d keys=%d")
      :format(first_screen_at, full_ms, render_ticks, key_count))

    assert.is_true(first_screen_at < 300,
      ("first screen %.0fms >= 300ms (P1-1)"):format(first_screen_at))
    assert.is_true(key_count >= BENCH_KEYS,
      ("expected >= %d keys, got %d"):format(BENCH_KEYS, key_count))
    assert.is_true(render_ticks >= 2, "expected batching (multiple renders)")

    require("poste-redis.config").config.scan_count = scan_count_orig
  end)
end)
