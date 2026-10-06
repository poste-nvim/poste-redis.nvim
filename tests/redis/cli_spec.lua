--- cli.run_async's failed-start contract (synced from poste-db c66a9ed):
--- whatever kills the start — a missing binary or a jobstart that RAISES
--- (E475, the binary stopped being executable between the lookup and the
--- start) — must reach the caller as the same synthesized on_exit(-1) + nil
--- return. An uncaught throw would skip every callback and leave the
--- caller's spinner running.
local saved_state = package.loaded["poste-redis.state"]

describe("poste-redis cli.run_async failed starts", function()
  after_each(function()
    package.loaded["poste-redis.state"] = saved_state
    package.loaded["poste-redis.cli"] = nil
  end)

  local function fresh_cli(find_binary)
    package.loaded["poste-redis.state"] = { find_poste_binary = find_binary }
    package.loaded["poste-redis.cli"] = nil
    return require("poste-redis.cli")
  end

  it("synthesizes on_exit(-1) when no binary is found", function()
    local cli = fresh_cli(function() return nil end)
    local exits = {}
    local job = cli.run_async({ "redis-exec" }, {
      on_exit = function(code) exits[#exits + 1] = code end,
    })
    assert.is_nil(job)
    assert.same({ -1 }, exits)
  end)

  it("survives jobstart raising E475 on a non-executable binary", function()
    local cli = fresh_cli(function()
      return "/nonexistent/poste-vanished-mid-session", "test"
    end)
    local exits = {}
    local job = cli.run_async({ "redis-exec" }, {
      on_exit = function(code) exits[#exits + 1] = code end,
      on_stdout = function() error("stdout must never fire for a job that never started") end,
    })
    assert.is_nil(job)
    assert.same({ -1 }, exits)
  end)

  it("survives a chansend THROW when the stdin stream is already closed", function()
    -- chansend on a dead stream RAISES ("Can't send data to closed stream"),
    -- it does not return -1: the process can die between jobstart and the
    -- stdin write. The unguarded write propagated the throw out of
    -- cli.run_async — past every on_error/on_exit — and left exec_run's
    -- busy flag stuck (red line #4).
    local cli = fresh_cli(function() return "/tmp/poste-fake", "test" end)
    local orig_jobstart = vim.fn.jobstart
    local orig_chansend = vim.fn.chansend
    vim.fn.jobstart = function() return 4242 end
    vim.fn.chansend = function() error("Can't send data to closed stream") end
    local exits = {}
    local ok, job = pcall(cli.run_async, { "redis-exec" }, {
      stdin = '{"connection":"redis://x"}',
      on_exit = function(code) exits[#exits + 1] = code end,
    })
    vim.fn.jobstart = orig_jobstart
    vim.fn.chansend = orig_chansend
    assert.truthy(ok, "run_async must not throw when the stdin write fails")
    assert.equals(4242, job)
    assert.same({}, exits, "the real job still owns the exit path")
  end)
end)
