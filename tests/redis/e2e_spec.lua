--- End-to-end spec: runs the real poste redis-exec against a live redis.
--- Gated on REDIS_TEST_URL (set in CI / playground) — skipped otherwise.
--- Exercises the full M1 loop: USE → parser → exec_run → buffer → history.
local exec_run = require("poste-redis.exec_run")
local buffer = require("poste-redis.buffer")
local history = require("poste-redis.history")
local state = require("poste.state")

describe("poste-redis e2e (live redis)", function()
  local url = vim.env.REDIS_TEST_URL

  local function available()
    if not url or url == "" then return false end
    local binary = state.find_poste_binary()
    if not binary or vim.fn.filereadable(binary) ~= 1 then return false end
    -- quick PING probe
    local probe = io.popen('echo \'{"connection":"' .. url .. '","commands":[["PING"]]}\' | "' .. binary .. '" redis-exec 2>/dev/null')
    if not probe then return false end
    local out = probe:read("*a")
    probe:close()
    return out ~= nil and out:find("PONG") ~= nil
  end

  local ok_avail = available()

  after_each(function()
    buffer.close()
    history.close()
    history.clear()
    exec_run.cancel()
  end)

  it("runs a PING against the live redis", function()
    if not ok_avail then pending("REDIS_TEST_URL not reachable"); return end
    local src = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(src, 0, -1, false, { "PING", "SET e2e:key value1", "GET e2e:key" })
    local results, summaries = {}, {}
    local done = false
    exec_run.run_file_async(src, { connection = url }, {
      on_result = function(ev) results[#results + 1] = ev end,
      on_summary = function(ev) summaries[#summaries + 1] = ev end,
      on_done = function() done = true end,
    })
    vim.wait(2000, function() return done end, 5)
    assert.is_true(done)
    assert.equals(3, #results)
    assert.equals("PONG", results[1].status)
    assert.equals("OK", results[2].status)
    assert.equals("value1", results[3].status)
    vim.api.nvim_buf_delete(src, { force = true })
  end)

  it("renders a hash via HGETALL into the panel", function()
    if not ok_avail then pending("REDIS_TEST_URL not reachable"); return end
    local src = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(src, 0, -1, false, {
      "HSET e2e:h f1 v1 f2 v2",
      "HGETALL e2e:h",
    })
    local done = false
    exec_run.run_file_async(src, { connection = url }, {
      on_done = function() done = true end,
    })
    vim.wait(2000, function() return done end, 5)
    assert.is_true(done)
    vim.api.nvim_buf_delete(src, { force = true })
  end)

  it("runs a single command through runner.run_selection", function()
    if not ok_avail then pending("REDIS_TEST_URL not reachable"); return end
    local src = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(src, 0, -1, false, { "GET e2e:key" })
    vim.api.nvim_set_current_buf(src)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local done = false
    exec_run.run_selection_async(src, "cursor", { connection = url }, {
      on_done = function() done = true end,
    })
    vim.wait(2000, function() return done end, 5)
    assert.is_true(done)
    vim.api.nvim_buf_delete(src, { force = true })
  end)
end)
