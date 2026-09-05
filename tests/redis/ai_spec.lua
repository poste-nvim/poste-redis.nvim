--- AI context spec — confirm gate + codeblock execution reporting.
--- exec_run and connections are stubbed; nothing touches a real redis.
local actions = require("poste-redis.ai.actions")
local redis_state = require("poste-redis.state")

describe("poste-redis ai actions", function()
  after_each(function()
    redis_state.context.connection = nil
    redis_state.current_url = nil
  end)

  describe("confirm_redis", function()
    local orig_confirm
    before_each(function()
      orig_confirm = vim.fn.confirm
    end)
    after_each(function()
      vim.fn.confirm = orig_confirm
    end)

    it("asks once per dangerous command and respects the refusal", function()
      local asked = 0
      vim.fn.confirm = function()
        asked = asked + 1
        return 2  -- No
      end
      assert.is_false(actions.confirm_redis("SET k v\nFLUSHALL\nGET x"))
      assert.equals(1, asked)
      vim.fn.confirm = function() return 1 end  -- Yes
      assert.is_true(actions.confirm_redis("SET k v\nFLUSHALL"))
    end)

    it("runs safe command lists without a dialog", function()
      local asked = 0
      vim.fn.confirm = function()
        asked = asked + 1
        return 1
      end
      assert.is_true(actions.confirm_redis("SET k v\nGET k"))
      assert.equals(0, asked)
    end)
  end)

  describe("execute_redis", function()
    local exec_run = require("poste-redis.exec_run")
    local connections = require("poste-redis.connections")
    local orig_run_file, orig_resolve

    before_each(function()
      orig_run_file = exec_run.run_file_async
      orig_resolve = connections.resolve_redis_url
      connections.resolve_redis_url = function() return "redis://stub:6379/0", nil end
      redis_state.context.connection = "stub"
      redis_state.current_url = "redis://stub:6379/0"
    end)

    after_each(function()
      exec_run.run_file_async = orig_run_file
      connections.resolve_redis_url = orig_resolve
    end)

    it("reports failure when a command in the block errored", function()
      local cbs
      exec_run.run_file_async = function(_buf, _opts, callbacks)
        cbs = callbacks
        return 7
      end
      local results = {}
      actions.execute_redis("SET a 1\nBADCMD", nil, function(ok) results[#results + 1] = ok end)
      cbs.on_done({
        { seq = 1, status = "OK" },
        { seq = 2, status = "error", error = "unknown command" },
      })
      assert.same({ false }, results, "command errors must report ok=false")
    end)

    it("reports success and survives an error+done double dispatch", function()
      -- run_async reports a process-level error and THEN reports done: the
      -- callback must fire exactly once (and the scratch buffer delete must
      -- not raise on the second pass)
      local cbs
      exec_run.run_file_async = function(_buf, _opts, callbacks)
        cbs = callbacks
        return 7
      end
      local results = {}
      actions.execute_redis("GET a", nil, function(ok) results[#results + 1] = ok end)
      cbs.on_error("boom")
      cbs.on_done({})  -- the trailing done dispatch after the error
      assert.same({ false }, results, "exactly one callback, reporting the failure")
    end)
  end)
end)
