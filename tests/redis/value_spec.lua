--- value viewer spec — per-type page commands + progressive pagination.
--- The session transport is stubbed in-process; no real redis.
local value = require("poste-redis.browser.value")
local buffer = require("poste-redis.buffer")
local session_conn = require("poste-redis.session_conn")

describe("poste-redis value viewer", function()
  local orig_execute

  before_each(function()
    orig_execute = session_conn.execute
  end)

  after_each(function()
    session_conn.execute = orig_execute
    buffer.close()
  end)

  local function make_node(key, typ)
    return {
      node_type = "key",
      meta = { key = key, url = "redis://stub:6379/0", connection = "stub", db = 0, type = typ },
    }
  end

  it("page_command builds per-type fetch commands", function()
    assert.same({ "HSCAN", "h", "0", "COUNT", "500" }, value._test.page_command("h", "hash", 0))
    assert.same({ "SSCAN", "s", "7", "COUNT", "500" }, value._test.page_command("s", "set", "7"))
    assert.same({ "LRANGE", "l", "500", "999" }, value._test.page_command("l", "list", "500"))
    assert.same({ "XRANGE", "st", "0", "+", "COUNT", "500" },
      value._test.page_command("st", "stream", "0"))
    assert.same({ "GET", "str" }, value._test.page_command("str", "string", nil))
  end)

  it("a multi-page hash advances past page 1 (done from the UPDATED cursor)", function()
    -- Regression: done was judged from the pre-update cursor, which is "0"
    -- on the very first call, so page 2 could never be fetched even though
    -- the page footer advertised "<Tab> next page"
    local pages_served = 0
    session_conn.execute = function(_url, _cmd, cbs)
      pages_served = pages_served + 1
      if pages_served == 1 then
        cbs.on_response({ value = { type = "map", entries = { { "a", "1" } },
          len = 2, cursor = "99" } })
      else
        cbs.on_response({ value = { type = "map", entries = { { "b", "2" } },
          len = 2, cursor = "0" } })
      end
      return "dispatched"
    end

    value.view(make_node("h", "hash"), nil, nil)
    assert.equals(1, #buffer._tabs(), "page 1 only before the switch")
    buffer.next_tab()  -- lands on the last (only) page: fetches page 2
    assert.equals(2, pages_served, "the next page must be fetched")
    assert.equals(2, #buffer._tabs())
    -- the viewer followed onto the newest page instead of snapping to page 1
    assert.equals(buffer._tabs()[2], buffer.active_tab())
  end)

  it("an exhausted cursor never fetches again", function()
    session_conn.execute = function(_url, _cmd, cbs)
      cbs.on_response({ value = { type = "map", entries = { { "a", "1" } },
        len = 1, cursor = "0" } })
      return "dispatched"
    end
    value.view(make_node("h", "hash"), nil, nil)
    buffer.next_tab()
    assert.equals(1, #buffer._tabs())
  end)

  it("stream pages advance via the exclusive last id and stop on a short page", function()
    -- Regression: the stream branch was missing from the page handler, so a
    -- stream rendered exactly one page and was marked done — the footer's
    -- paging hint never had a next page behind it.
    local cmds = {}
    local pages_served = 0
    local function ids(n, start)
      local out = {}
      for i = start, start + n - 1 do
        out[#out + 1] = { id = tostring(i) .. "-1", fields = { { "k", "v" } } }
      end
      return out
    end
    session_conn.execute = function(_url, cmd, cbs)
      cmds[#cmds + 1] = cmd
      pages_served = pages_served + 1
      if pages_served == 1 then
        cbs.on_response({ value = { type = "stream", value = ids(500, 1), len = 803 } })
      else
        cbs.on_response({ value = { type = "stream", value = ids(303, 501), len = 803 } })
      end
      return "dispatched"
    end

    value.view(make_node("st", "stream"), nil, nil)
    assert.equals(1, #buffer._tabs())
    buffer.next_tab()  -- lands on the last page: fetches page 2
    assert.equals(2, pages_served, "the next stream page must be fetched")
    -- page 2 continues from the exclusive last id of page 1 (Redis 6.2 `(`)
    assert.same({ "XRANGE", "st", "(500-1", "+", "COUNT", "500" }, cmds[2])
    assert.equals(2, #buffer._tabs())
  end)

  it("a slow fetch for a superseded view never lands in the new view's tabs", function()
    -- Regression: add_page bound to the current global view, so a response
    -- from key A arriving after key B was opened appended A's page (labeled
    -- with B's key) into B's tab list.
    local deferred = nil
    session_conn.execute = function(_url, _cmd, cbs)
      if deferred == nil then
        deferred = cbs  -- key A's fetch: held until the test releases it
      else
        cbs.on_response({ value = { type = "string", value = "B" } })
      end
      return "dispatched"
    end

    value.view(make_node("a", "string"), nil, nil)
    value.view(make_node("b", "string"), nil, nil)
    assert.equals(1, #buffer._tabs(), "only B's page so far")
    assert.equals("b", buffer.active_tab().meta.key)

    deferred.on_response({ value = { type = "string", value = "A" } })
    assert.equals(1, #buffer._tabs(), "A's late page must be dropped")
    assert.equals("b", buffer.active_tab().meta.key)
  end)

  it("load_full fetches via run_async and renders one full tab", function()
    -- Regression: load_full used exec_run.run_sync, so fetching a near-cap
    -- value blocked the whole UI on `F`.
    local exec_run = require("poste-redis.exec_run")
    local orig_run_async = exec_run.run_async
    local captured = nil
    exec_run.run_async = function(entries, opts, cbs)
      captured = { entries = entries, opts = opts, cbs = cbs }
      return 1
    end

    session_conn.execute = function(_url, _cmd, cbs)
      cbs.on_response({ value = { type = "string", value = "trunc…" } })
      return "dispatched"
    end
    value.view(make_node("big", "string"), nil, nil)

    value.load_full()
    assert.is_not_nil(captured, "the exec run must be dispatched async")
    assert.same({ "GET", "big" }, captured.entries[1].tokens)
    assert.equals(1024 * 1024 * 64, captured.opts.max_bytes)
    assert.equals(1, #buffer._tabs(), "nothing rendered before the reply")

    captured.cbs.on_result({ value = { type = "string", value = "the whole value" } })
    exec_run.run_async = orig_run_async
    assert.equals(1, #buffer._tabs(), "the full load REPLACES the page list")
    assert.equals("big [string · full]", buffer.active_tab().meta.title)
    assert.equals("the whole value", buffer.active_tab().meta.value.value)
  end)

  it("load_full drops a reply for a superseded view and never renders it", function()
    local exec_run = require("poste-redis.exec_run")
    local orig_run_async = exec_run.run_async
    local captured = nil
    exec_run.run_async = function(entries, opts, cbs)
      captured = cbs
      return 1
    end

    session_conn.execute = function(_url, _cmd, cbs)
      cbs.on_response({ value = { type = "string", value = "trunc…" } })
      return "dispatched"
    end
    value.view(make_node("a", "string"), nil, nil)
    value.load_full()
    value.view(make_node("b", "string"), nil, nil)

    captured.on_result({ value = { type = "string", value = "stale A" } })
    exec_run.run_async = orig_run_async
    assert.equals("b", buffer.active_tab().meta.key, "stale full load must not render")
    assert.equals(1, #buffer._tabs())
  end)
end)
